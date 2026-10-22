# Domenia 2 — contrat des opérations du pont

Ce document fixe, opération par opération, ce que la page web peut demander au moteur et la forme **exacte** de la
réponse. Il couvre le shell, la page Accueil et l’OU de travail : `app.info`, `session.info`, `dashboard.summary`,
`dashboard.widget.refresh`, `dashboard.widget.setEnabled`, `directory.ou.children`, `directory.ou.search` et
`session.setScope`. Le circuit des écritures (§ 12, [`WRITES.md`](WRITES.md)) ajoute `accounts.unlock.plan`,
`write.execute`, `write.receipts.list`, `write.receipts.get` et `write.receipts.verify`. La conception du mode simulation
qui sert ces opérations sans Active Directory est dans
[`SIMULATION.md`](SIMULATION.md) ; l’organisation du moteur en modules (un par écran, trouvés tout seuls) est dans
[`PLATFORM.md`](PLATFORM.md).

Toute opération absente de ce document est refusée par le pont (`operation.unknown`). Ajouter une opération, c’est
d’abord l’écrire ici.

## 1. Conventions communes

### 1.1 Enveloppe (inchangée, `Domenia.Bridge/BridgeMessages.cs`)

Requête de la page :

```json
{ "id": "r1k2x3", "op": "dashboard.widget.refresh", "args": { "id": "lockedAccounts" } }
```

Réponse du moteur, réussite puis échec :

```json
{ "id": "r1k2x3", "kind": "result", "op": "dashboard.widget.refresh", "data": { } }
```

```json
{ "id": "r1k2x3", "kind": "error", "op": "dashboard.widget.refresh", "data": null,
  "error": { "code": "widget.disabled", "message": "Ce widget est désactivé : aucune mesure n’est faite. Réactivez « Mesure active » pour l’actualiser." } }
```

- `kind` vaut `result`, `error` ou `event`. Un événement porte `op` = `<opération>:<nom>` (aucune des opérations de ce
  document n’en émet pour l’instant).
- `error` n’est présent que si `kind` = `error`. Partout ailleurs, **les champs nuls sont écrits** (`"x": null`) : la
  page peut compter sur la présence de chaque champ décrit ici.

### 1.2 Règles JSON

| Sujet | Règle |
|---|---|
| Noms | camelCase ASCII, exactement ceux de ce document. Aucun champ supplémentaire sans mise à jour du document. |
| Date et heure | Texte ISO 8601 **UTC, à la seconde, suffixe `Z`** : `"2026-10-21T16:14:00Z"`. La page affiche en heure locale. |
| Date seule | Texte `yyyy-MM-dd`, jour civil **local** du poste : `"2026-10-21"`. |
| Durée | Texte ISO 8601 : `"P7D"` (7 jours). |
| Entiers | Nombres JSON entiers (comptes d’objets, octets). |
| Pourcentages | Nombre de 0 à 100 arrondi **au dixième** (`84.0`, `6.4`), jamais une fraction de 0 à 1. |
| Énumérations | Textes en camelCase (`"alert"`, `"kpi"`, `"simulation"`). |
| Tons | `ok`, `warn`, `alert`, `info`, `off` : directement utilisables dans `data-tone` de la page. |
| Textes | Français soigné, apostrophe typographique ’, espace fine insécable (U+202F) comme séparateur de milliers (`1 186`), espace insécable (U+00A0) avant « : » et « % », virgule décimale (`3,1 %`), signe moins U+2212 (`−3`). Ils sont produits par le moteur, la page les affiche tels quels après `esc()`. Les exemples de ce document montrent ces espaces comme des espaces ordinaires. |
| Absence de mesure | Une mesure inconnue vaut `null`, **jamais 0**. |
| Secrets | Aucun mot de passe, jeton, clé LAPS ou BitLocker dans aucune réponse. Seules des **dates** d’expiration circulent. |

### 1.3 Classes d’opération (`OperationClass`)

| Classe | Ce que l’opération peut faire |
|---|---|
| `Local` | Calcul ou état en mémoire ; ni disque, ni réseau. |
| `LocalRead` | Lecture de la base locale ou des fichiers de l’application. |
| `NetworkRead` | Lecture annuaire, WMI, DNS ou ping, seulement après un geste explicite de l’opérateur, bornée à une OU. |
| `LocalWrite` | Écriture des **données locales de l’application seulement** : préférences (`%LOCALAPPDATA%\Domenia\preferences.json`, ou `preferences-simulation.json` en simulation), reçus d’écriture (`receipts.jsonl`, ou `receipts-simulation.jsonl`, § 12.6) et documents demandés par l’opérateur (`Exports`, ou `Exports-simulation`, toujours un nouveau fichier daté, jamais remplacé, rien en capture ni en E2E : `EngineContext.Documents`, [`PLATFORM.md`](PLATFORM.md) § 3.3), atomique ; jamais l’annuaire, jamais un poste. **Admise en simulation** (§ 1.5). |
| `Write` | Écriture AD ou action distante, **seulement par `write.execute`** (§ 12) : plan, confirmation, reçu, relecture. **Admise en simulation sur la surcouche en mémoire de l’annuaire fictif, sans effet réel** (§ 1.5, décision du 21/10) ; toute autre opération `Write` est refusée dans les deux modes. |

La classe déclarée est celle du **mode annuaire** (le cas le plus exigeant). En simulation, le même nom d’opération
garde la même classe et les mêmes règles d’admission, même si son gestionnaire ne touche ni réseau ni disque. Seules
exceptions : les lectures que la simulation sert en mémoire et que le mode annuaire fait sur le contrôleur, déclarées
`LocalRead` en simulation et `NetworkRead` en mode annuaire : l’arborescence (`directory.ou.children`,
`directory.ou.search`) et les plans d’écriture (`accounts.unlock.plan`, § 12).

Une écriture locale qui échoue (disque plein, droits) ne fait jamais échouer l’opération : le choix vaut pour la session,
le journal technique trace le type d’erreur et le journal des opérations affiche « Préférences non enregistrées : … »
(ton `warn`). Un document de préférences illisible est ignoré (valeurs par défaut) et mis de côté une fois
(`.illisible`) avant d’être remplacé (`PLATFORM.md` § 5).

### 1.4 Codes d’erreur communs (déjà produits par `BridgeDispatcher`)

| Code | Message | Cause |
|---|---|---|
| `message.size` | Message de l’interface refusé : taille non admise. | Message vide ou de plus de 1 Mo. |
| `message.json` | Message de l’interface illisible. | JSON invalide. |
| `message.id` | Message de l’interface sans identifiant valide. | `id` absent, vide ou de plus de 64 caractères. |
| `operation.unknown` | Opération inconnue : rien n’a été exécuté. | Nom absent du registre. |
| `operation.cancelled` | Opération annulée. | Fermeture de l’application pendant le traitement. |
| `operation.failed` | L’opération a échoué. Le détail technique est dans le journal. | Erreur imprévue (tracée par l’hôte). |

Codes communs ajoutés par ce contrat :

| Code | Message | Cause |
|---|---|---|
| `arguments.invalid` | Arguments invalides : *précision*. | `args` d’une forme non admise (voir chaque opération). Le message ne recopie jamais la saisie de la page. |
| `simulation.readOnly` | Écritures désactivées en simulation : aucune écriture tentée. | Toute opération de classe `Write` autre que `write.execute` en simulation, refusée **avant** son gestionnaire. |
| `simulation.unavailable` | Non disponible en simulation : aucune connexion au poste ni à l’annuaire. | Opération `NetworkRead` que l’annuaire fictif ne sert pas, refusée **avant** son gestionnaire. |
| `write.unavailable` | Écritures non disponibles dans cette version : aucune écriture tentée. | Mode annuaire : toute opération de classe `Write` autre que `write.execute` (et toute classe que la garde ne connaît pas), refusée **avant** son gestionnaire : seule la porte du circuit d’écriture écrit (§ 12). |
| `source.unavailable` | Lecture de l’annuaire indisponible dans cette version : lancez Domenia avec --simulation pour l’essayer sans Active Directory. | Mode annuaire tant que `Domenia.Ad` n’est pas branché. |
| `ou.unknown` | OU introuvable : rien n’a été lu. | DN bien formé qui ne désigne ni la racine du domaine ni une OU (conteneur `CN=…`, OU absente, autre domaine). |
| `scope.unknown` | OU introuvable : l’OU de travail n’a pas été changée. | `session.setScope` vers une OU absente ou un conteneur. |
| `scope.outsideDomain` | Cette OU n’appartient pas au domaine de la session : l’OU de travail n’a pas été changée. | `session.setScope` vers un DN d’un autre domaine. |

Précisions fixes de `arguments.invalid` :

- « cette opération n’en accepte aucun. » — `args` porte des propriétés alors que l’opération n’en prend pas ;
- « un objet JSON est attendu. » — `args` n’est pas un objet ;
- « propriété non admise. » — propriété inconnue ou en double ;
- « « id » est obligatoire et doit être un texte. » (de même pour « text » et « dn » quand ils sont obligatoires) ;
- « « enabled » est obligatoire et doit valoir true ou false. » (de même pour « subtree ») ;
- « « dn » doit être un texte ou null. » ;
- « « dn » doit être un nom distinctif valide. » — DN vide, mal formé (RFC 4514) ou de plus de 2 048 caractères ;
- « « text » doit faire au plus 100 caractères. ».

Une opération sans argument accepte `args` absent, `null` ou `{}`.

Les codes et précisions du circuit d’écriture (`write.*`, `receipt.*`) sont au § 12.7.

### 1.5 Admission en simulation

En simulation, le dispatcher admet `write.execute`, la seule opération de classe `Write`, dont les exécuteurs de la
simulation n’écrivent que dans la surcouche en mémoire de l’annuaire fictif (décision de David du 21/10 : écritures
testables en simulation, sans effet réel ; `WRITES.md` § 5) ; il refuse toute autre opération `Write` avec
`simulation.readOnly`, sans appeler le gestionnaire, même si sa déclaration la marque servie ; les classes `Local`,
`LocalRead` et `LocalWrite` (préférences et reçus de la simulation, jamais l’annuaire) sont admises, et toute classe
ajoutée plus tard est refusée tant que la garde ne la connaît pas. Une opération `NetworkRead` n’est admise que si sa déclaration la marque servie par l’annuaire fictif
(`OperationDefinition.ServedInSimulation`, aujourd’hui `dashboard.widget.refresh` et `write.receipts.verify`) ; toute autre (outils
distants à venir) est refusée par défaut, sans appeler le gestionnaire, avec `simulation.unavailable` : « Non
disponible en simulation : aucune connexion au poste ni à l’annuaire. » (parité avec `DOMENIA_DEMO_WRITE` et
`DOMENIA_DEMO_UNAVAILABLE` de Domenia 1). Chaque refus du pont (message, opération, admission, arguments) est tracé
dans le journal technique par son code et le nom d’opération déclaré, jamais par le contenu du message.

En mode annuaire, la garde `AdmissionGuards.ReadOnlyDirectory` admet `write.execute` (circuit complet : plan,
confirmation, reçu avant l’envoi, relecture, § 12) et refuse toute autre opération de classe `Write`, et toute classe
qu’elle ne connaît pas, avec `write.unavailable`, sans appeler le gestionnaire : la lecture seule par défaut ne dépend
d’aucun module (`AdmissionGuards.IsWriteCircuit`). `Local`, `LocalRead`, `LocalWrite` et `NetworkRead` sont admises. Un
test construit le registre réel (tous les modules trouvés dans les assemblages Domenia) et vérifie que `write.execute` y
est la seule opération de classe `Write`, admise dans les deux modes.

### 1.6 Récapitulatif

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `app.info` | `Local` | aucun | identité de l’application et mode |
| `session.info` | `LocalRead` | aucun | session, domaine, contrôleur, OU de travail, base locale |
| `dashboard.summary` | `LocalRead` | aucun | tous les widgets de l’Accueil |
| `dashboard.widget.refresh` | `NetworkRead` | `{ id }` | le widget remesuré |
| `dashboard.widget.setEnabled` | `LocalWrite` | `{ id, enabled }` | le widget dans son nouvel état, mémorisé |
| `directory.ou.children` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ dn }` (texte ou `null`) | l’OU (ou la racine) et ses OU enfants |
| `directory.ou.search` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ text }` | tableau d’au plus 50 OU |
| `session.setScope` | `LocalWrite` | `{ dn, subtree }` | `session.info` à jour |
| `accounts.unlock.plan` | `LocalRead` en simulation, `NetworkRead` en mode annuaire | `{ dn }` | plan du déverrouillage et son jeton (§ 12.2) |
| `write.execute` | `Write` | `{ planId, token, typedName }` | reçu de l’écriture (§ 12.3) |
| `write.receipts.list` | `LocalRead` | aucun | reçus du mode, à vérifier d’abord (§ 12.4) |
| `write.receipts.get` | `LocalRead` | `{ id }` | un reçu complet (§ 12.5) |
| `write.receipts.verify` | `NetworkRead` (servie en simulation) | `{ id }` | le reçu après relecture de son objet (§ 12.5) |

---

## 2. `app.info`

Identité de l’application, du moteur web et du **mode** de fonctionnement. Appelée au démarrage par le shell, avant
tout le reste : c’est elle qui décide de l’affichage de la bannière de simulation.

- **Classe** : `Local`.
- **Arguments** : aucun.
- **Erreurs** : `arguments.invalid` seulement.

### Résultat

| Champ | Type | Contenu |
|---|---|---|
| `name` | texte | `"Domenia"`. |
| `version` | texte | `ProductInfo.Version`, par exemple `"2.0.0-dev"`. |
| `runtime` | texte | Version de .NET embarquée, par exemple `"10.0.12"`. |
| `webViewRuntime` | texte | `"embarque"` (moteur fixe du pack) ou `"windows"` (moteur installé). La maquette du navigateur renvoie `"apercu"`. |
| `mode` | texte | `"simulation"` ou `"annuaire"`. |
| `modeLabel` | texte | `"Simulation"` ou `"Annuaire Active Directory"`. |
| `modeReason` | texte | Pourquoi ce mode : `argument`, `environment`, `environmentOptOut`, `configuration`, `notDomainJoined`, `joinStateUnknown`, `domainJoined` (voir `SIMULATION.md` § 2). |
| `modeDetail` | texte | Phrase pour l’opérateur expliquant le choix du mode. |
| `banner` | texte ou `null` | Texte de la bannière permanente ; `null` en mode annuaire. La page l’affiche dès qu’il n’est pas nul. |

### Exemple (simulation lancée avec `--simulation`)

```json
{
  "name": "Domenia",
  "version": "2.0.0-dev",
  "runtime": "10.0.12",
  "webViewRuntime": "embarque",
  "mode": "simulation",
  "modeLabel": "Simulation",
  "modeReason": "argument",
  "modeDetail": "Lancé avec l’option --simulation.",
  "banner": "Simulation : annuaire fictif example.local, aucune connexion à Active Directory ; les écritures ne modifient que cet annuaire fictif, en mémoire."
}
```

Textes de `modeDetail` :

| `modeReason` | `modeDetail` |
|---|---|
| `argument` | Lancé avec l’option --simulation. |
| `environment` | Variable DOMENIA_SIMULATION=1 présente. |
| `notDomainJoined` | Ce poste n’est joint à aucun domaine : démarrage en simulation. |
| `joinStateUnknown` | Appartenance du poste à un domaine illisible : démarrage en simulation. Pour forcer l’annuaire, définissez DOMENIA_SIMULATION=0. |
| `domainJoined` | Poste joint au domaine *nom DNS du domaine*. |
| `environmentOptOut` | Variable DOMENIA_SIMULATION=0 : mode annuaire demandé. |
| `configuration` | Réglage Auth.DemoProvider de Domenia.config.json : démarrage en simulation. |

---

## 3. `session.info`

État de la session : qui est connecté, à quel domaine et quel contrôleur, sur quel périmètre, avec quels droits
estimés, et l’état de la base locale. Alimente la barre supérieure, le héros (titre « Vue d’ensemble · OU *libellé* »,
puces compte, domaine, contrôleur, OU) et l’onglet « Session » de « Session et vérifications ». Pas de salutation par
prénom (décision de David du 21/10) : l’opérateur travaille avec un compte d’administration, affiché en puce.

- **Classe** : `LocalRead` : l’OU de travail mémorisée est relue dans le fichier des préférences au premier appel et
  vérifiée dans l’index local des OU (`IOrganizationalUnitIndex` : mémoire en simulation, base locale en mode annuaire),
  jamais par le réseau.
- **Arguments** : aucun.
- **Erreurs** : `arguments.invalid` seulement. En mode annuaire non connecté, l’opération répond quand même, avec
  `connection.state` = `disconnected` et les champs inconnus à `null`.

### Résultat

| Champ | Type | Contenu |
|---|---|---|
| `connection.state` | texte | `simulated`, `connected` ou `disconnected`. |
| `connection.label` | texte | `Annuaire simulé`, `Annuaire connecté`, `Annuaire non connecté` (texte de `.live`). |
| `domain` | objet ou `null` | `dnsName`, `netbiosName`, `rootDn` (racine du domaine). |
| `controller` | objet ou `null` | `dnsName` (FQDN du contrôleur), `site` (texte ou `null`). |
| `account.login` | texte | Compte au format `DOMAINE\compte`. |
| `account.displayName` | texte ou `null` | Nom affiché du compte. |
| `account.givenName` | texte ou `null` | Prénom du compte. La page ne s’en sert plus pour saluer (décision du 21/10) ; il reste dans le contrat. |
| `account.dn` | texte ou `null` | DN du compte. |
| `authentication.method` | texte | `none` (simulation), `windowsSession`, `explicitCredentials`. |
| `authentication.protocol` | texte ou `null` | `kerberos`, `ntlm` ou `null` si inconnu. |
| `authentication.label` | texte | Libellé affiché : `Aucune (simulation)`, `Kerberos`, `NTLM`, `Session Windows`. |
| `scope` | objet ou `null` | OU de travail de la session (§ 11), défaut de toutes les sections sans choix propre : `dn`, `label` (nom de l’OU, ou nom DNS du domaine pour tout le domaine), `subtree` (booléen). `null` en mode annuaire non connecté. |
| `rights.level` | texte | `read`, `delegated`, `admin` ou `unknown`. |
| `rights.label` | texte | `Lecture`, `Délégués`, `Administration`, `Non évalués`. |
| `rights.estimated` | booléen | Toujours `true` tant que les droits sont déduits des groupes et non vérifiés par l’annuaire. |
| `rights.detail` | texte | Phrase d’explication. |
| `readOnly` | booléen | Lecture seule active : `true` quand aucune écriture n’est admise (mode annuaire tant que `Domenia.Ad` n’est pas branché) ; `false` en simulation, où les écritures sont admises sur la surcouche en mémoire de l’annuaire fictif (décision du 21/10, § 12). Même `false`, rien n’est écrit sans plan confirmé. |
| `tasks.running` | entier | Lectures en cours (actualisations de widgets comprises). |
| `tasks.queued` | entier | Lectures en attente. |
| `cache.state` | texte | `fresh` (moins de 24 h), `aging` (1 à 7 jours), `stale` (plus de 7 jours), `empty` (jamais lue). |
| `cache.label` | texte | `À jour`, `À relire bientôt`, `Ancienne`, `Vide`. |
| `cache.lastReadAt` | date-heure ou `null` | Dernière lecture de l’annuaire enregistrée dans la base locale. En simulation : date fictive de lecture de l’annuaire fictif (la base locale n’est jamais ouverte, `SIMULATION.md` § 1). |
| `cache.objects` | entier | Objets d’annuaire dans la base (utilisateurs, ordinateurs, groupes, OU). |
| `cache.complete` | booléen | `false` si la dernière lecture s’est arrêtée à sa limite (chiffres possiblement sous-estimés). |
| `onboarding.steps` | tableau | 4 étapes `{ id, label, done }` dans l’ordre : `connect`, `scope`, `firstRead`, `dashboard`. |
| `onboarding.completed` | entier | Nombre d’étapes faites. |
| `onboarding.total` | entier | `4`. |

L’étape `dashboard` est faite dès qu’un `dashboard.summary` a réussi dans la session.

### Exemple (simulation, avant le premier tableau de bord)

```json
{
  "connection": { "state": "simulated", "label": "Annuaire simulé" },
  "domain": { "dnsName": "example.local", "netbiosName": "EXAMPLE", "rootDn": "DC=example,DC=local" },
  "controller": { "dnsName": "DC01.example.local", "site": "Paris" },
  "account": {
    "login": "EXAMPLE\\j.martin",
    "displayName": "Julien Martin",
    "givenName": "Julien",
    "dn": "CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,DC=example,DC=local"
  },
  "authentication": { "method": "none", "protocol": null, "label": "Aucune (simulation)" },
  "scope": { "dn": "OU=Postes,DC=example,DC=local", "label": "Postes", "subtree": true },
  "rights": {
    "level": "read",
    "label": "Lecture",
    "estimated": true,
    "detail": "Simulation : les droits sont fictifs ; les écritures ne modifient que l’annuaire fictif, en mémoire."
  },
  "readOnly": false,
  "tasks": { "running": 0, "queued": 0 },
  "cache": {
    "state": "fresh",
    "label": "À jour",
    "lastReadAt": "2026-10-21T16:14:00Z",
    "objects": 1826,
    "complete": true
  },
  "onboarding": {
    "steps": [
      { "id": "connect", "label": "Connexion à l’annuaire", "done": true },
      { "id": "scope", "label": "Choix de l’OU de travail", "done": true },
      { "id": "firstRead", "label": "Première lecture", "done": true },
      { "id": "dashboard", "label": "Tableau de bord", "done": false }
    ],
    "completed": 3,
    "total": 4
  }
}
```

### Exemple (mode annuaire, `Domenia.Ad` pas encore branché)

```json
{
  "connection": { "state": "disconnected", "label": "Annuaire non connecté" },
  "domain": { "dnsName": "cnamts.local", "netbiosName": null, "rootDn": null },
  "controller": null,
  "account": { "login": "CNAMTS\\degun", "displayName": null, "givenName": null, "dn": null },
  "authentication": { "method": "windowsSession", "protocol": null, "label": "Session Windows" },
  "scope": null,
  "rights": { "level": "unknown", "label": "Non évalués", "estimated": true, "detail": "Droits évalués à la connexion à l’annuaire." },
  "readOnly": true,
  "tasks": { "running": 0, "queued": 0 },
  "cache": { "state": "empty", "label": "Vide", "lastReadAt": null, "objects": 0, "complete": false },
  "onboarding": {
    "steps": [
      { "id": "connect", "label": "Connexion à l’annuaire", "done": false },
      { "id": "scope", "label": "Choix de l’OU de travail", "done": false },
      { "id": "firstRead", "label": "Première lecture", "done": false },
      { "id": "dashboard", "label": "Tableau de bord", "done": false }
    ],
    "completed": 0,
    "total": 4
  }
}
```

Ici, `domain.dnsName` provient de l’état local du poste (`NetGetJoinInformation`) et `account.login` du jeton Windows du
processus : aucune des deux lectures ne passe par le réseau. `netbiosName` n’est connu qu’après connexion.

---

## 4. Les widgets de l’Accueil

### 4.1 Liste fermée

Chaque widget a un identifiant stable en camelCase, utilisé comme clé de `dashboard.summary.widgets` et comme `id` des
deux opérations de widget. Tout autre identifiant est refusé (`widget.unknown`).

| `id` | `kind` | Titre | Périmètre | Famille de mesure | Équivalent Domenia 1 |
|---|---|---|---|---|---|
| `workstationsOnline` | `kpi` | Postes en ligne | OU de travail | présence | `fleet.presence` |
| `activeAccounts` | `kpi` | Comptes actifs | domaine | annuaire | (nouveau ; règle `Get-DomeniaAccountState`) |
| `lockedAccounts` | `kpi` | Comptes verrouillés | domaine | annuaire | (nouveau ; bit 0x10 du calcul du contrôleur) |
| `passwordsExpiring` | `kpi` | Mots de passe expirant sous 7 jours | domaine | annuaire | (nouveau ; règle d’expiration de la fiche compte) |
| `diskAlerts` | `kpi` | Alertes disque | OU de travail | inventaire | `fleet.lowdisk` |
| `osDistribution` | `distribution` | Systèmes d’exploitation | OU de travail | annuaire | `fleet.os`, `fleet.versions` |
| `workstationActivity` | `series` | Activité des postes · 7 jours | OU de travail | calcul local | `fleet.trend` (instantanés quotidiens) |
| `measureFreshness` | `gauge` | Fraîcheur des mesures | OU de travail | présence | couverture des mesures (point 3, FI-04) |
| `watchlist` | `list` | Postes à surveiller | OU de travail | calcul local | `fleet.attention` |
| `recentOperations` | `timeline` | Dernières opérations | session | calcul local | journal des opérations |

Les comptes (actifs, verrouillés, mots de passe) couvrent **tout le domaine** : l’OU de travail `OU=Postes` ne contient
pas d’utilisateurs. Les widgets de postes couvrent l’OU de travail (`session.info.scope`, § 11), sous-arborescence
comprise si `subtree` est vrai. Leur `scopeLabel` vaut `OU <nom>`, ou `Domaine <nom DNS>` quand l’OU de travail est tout
le domaine. L’historique quotidien des chiffres de postes (`history`, `delta`, jours passés de `workstationActivity`)
appartient à l’OU pour laquelle il a été relevé : pour une autre OU de travail, ces jours sont **absents** (seul le
point du jour reste, `delta` = `null`), jamais repris comme s’ils étaient les siens.

### 4.2 Champs communs à tous les widgets

| Champ | Type | Contenu |
|---|---|---|
| `id` | texte | Identifiant de la liste fermée. |
| `kind` | texte | `kpi`, `distribution`, `series`, `gauge`, `list` ou `timeline`. |
| `title` | texte | Titre affiché. |
| `scopeLabel` | texte | `Domaine example.local`, `OU Postes` ou `Session`. |
| `enabled` | booléen | `false` : mesure désactivée par l’opérateur ; la carte reste au tableau, grisée. |
| `tone` | texte | Ton global de la carte (`ok`, `warn`, `alert`, `info`, `off`). `off` si désactivé, sans mesure ou périmé. |
| `measuredAt` | date-heure ou `null` | Date de la mesure utilisée ; `null` si désactivé ou jamais mesuré. |
| `stale` | booléen | `true` si `measuredAt` a plus de 7 jours : la carte est grisée (règle FI-04 de Domenia 1). |
| `detail` | texte | Une phrase : source, seuil et limites de la mesure. |
| `data` | objet ou `null` | Contenu propre au `kind`. **`null` si et seulement si** `enabled` = `false` ou si aucune mesure n’existe. |

Widget désactivé (forme unique, quel que soit le `kind`) :

```json
{
  "id": "lockedAccounts",
  "kind": "kpi",
  "title": "Comptes verrouillés",
  "scopeLabel": "Domaine example.local",
  "enabled": false,
  "tone": "off",
  "measuredAt": null,
  "stale": false,
  "detail": "Mesure désactivée : ce widget ne lit rien tant qu’il n’est pas réactivé.",
  "data": null
}
```

Widget actif jamais mesuré (par exemple aucun relevé d’inventaire) : `enabled` = `true`, `tone` = `off`,
`measuredAt` = `null`, `data` = `null`, et `detail` dit quoi faire (« Aucun relevé d’inventaire : actualisez ce widget
pour mesurer l’espace disque. »).

### 4.3 `data` d’un widget `kpi`

| Champ | Type | Contenu |
|---|---|---|
| `value` | entier | Valeur affichée (cible du count-up). |
| `total` | entier ou `null` | Dénominateur quand il a un sens (`287 / 412`) ; `null` sinon. |
| `unit` | texte | `postes` ou `comptes`. |
| `delta` | objet ou `null` | Écart avec la valeur d’il y a 7 jours ; `null` si ce point manque dans l’historique. |
| `delta.value` | entier | Écart signé (`9`, `-1`, `0`). |
| `delta.period` | durée | `"P7D"`. |
| `delta.label` | texte | `+9 sur 7 jours`, `−1 sur 7 jours`, `Stable sur 7 jours`. |
| `delta.tone` | texte | Sens de l’écart pour ce widget (voir § 4.8). |
| `history` | tableau | 0 à 14 points `{ date, value }`, du plus ancien au plus récent, le dernier étant aujourd’hui. **Un jour sans instantané est absent** (jamais 0) ; la page ne suppose pas 14 points. |
| `breakdown` | tableau | Ventilation `{ key, label, value, tone }`, ordre fixe, toujours toutes les clés du widget (valeur 0 comprise). |

Clés de `breakdown` :

| Widget | Clés (dans l’ordre) |
|---|---|
| `workstationsOnline` | `online` En ligne (`ok`), `noAnswer` Sans réponse (`warn`), `notChecked` Non vérifié (`off`). Somme = `total`. |
| `activeAccounts` | `enabled` Actifs (`ok`), `disabled` Désactivés (`off`). |
| `lockedAccounts` | `locked` Verrouillés (`alert`), `toCheck` À vérifier (`off`) : `lockoutTime` non nul sans calcul du contrôleur lisible. |
| `passwordsExpiring` | `expiring` Expirent sous 7 jours (`warn`), `expired` Déjà expirés (`alert`), `mustChange` À changer à la prochaine connexion (`info`), `neverExpires` N’expirent jamais (`off`). Comptes actifs seulement. |
| `diskAlerts` | `critical` Moins de 10 % libre (`alert`), `tight` 10 à 20 % libre (`warn`), `healthy` 20 % et plus (`ok`), `unknown` Sans relevé (`off`). Somme = postes actifs de l’OU. |

### 4.4 `data` d’un widget `distribution` (`osDistribution`)

| Champ | Type | Contenu |
|---|---|---|
| `total` | entier | Comptes ordinateur activés du périmètre. |
| `unit` | texte | `postes`. |
| `centerText` | texte | Texte au centre de l’anneau : `412 postes`. |
| `segments` | tableau | Au plus 5 segments `{ key, label, value, percent, members }` : les 4 plus grands, puis `autres`. Ordre : valeur décroissante, égalité par libellé ; `autres` toujours en dernier. |
| `segments[].members` | tableau de textes | Pour `autres`, les libellés regroupés ; `[]` pour les autres segments. |
| `lead` | objet | Segment dominant : `{ label, percent }`. |

Les éditions d’une même version sont regroupées (« Windows 11 Entreprise 24H2 » et « Windows 11 Professionnel 24H2 »
donnent « Windows 11 24H2 »). Les pourcentages sont arrondis au dixième par la méthode du plus fort reste : **leur somme
vaut exactement 100.0**. Un système non renseigné forme le segment `nonRenseigne` « Système non renseigné ».

### 4.5 `data` d’un widget `series` (`workstationActivity`)

| Champ | Type | Contenu |
|---|---|---|
| `unit` | texte | `postes`. |
| `max` | entier | Plus grande valeur non nulle (échelle des barres) ; `0` si aucune. |
| `points` | tableau | **Toujours 7 points** `{ date, label, value, partial }`, du plus ancien à aujourd’hui. |
| `points[].label` | texte | Jour abrégé : `lun.`, `mar.`, `mer.`, `jeu.`, `ven.`, `sam.`, `dim.` (libellés figés, indépendants de la culture du poste). |
| `points[].value` | entier ou `null` | Postes distincts ayant répondu au relevé de présence ce jour-là ; `null` sans instantané (la barre est absente, pas à 0). |
| `points[].partial` | booléen | `true` pour aujourd’hui (journée en cours). |

### 4.6 `data` d’un widget `gauge` (`measureFreshness`)

| Champ | Type | Contenu |
|---|---|---|
| `percent` | nombre | Part des postes actifs du périmètre mesurés depuis moins de `freshDays` jours. |
| `fresh` | entier | Postes mesurés récemment. |
| `total` | entier | Postes actifs du périmètre. |
| `freshDays` | entier | `7`. |
| `breakdown` | tableau | `recent` Moins de 7 jours (`ok`), `aging` 7 à 30 jours (`warn`), `expired` Plus de 30 jours (`alert`), `never` Jamais relevé (`off`). Somme = `total`. |

### 4.7 `data` des widgets `list` (`watchlist`) et `timeline` (`recentOperations`)

`watchlist` :

| Champ | Type | Contenu |
|---|---|---|
| `total` | entier | Postes du périmètre ayant au moins un point d’attention. |
| `shown` | entier | Lignes renvoyées (au plus 6). |
| `rows[].name` | texte | Nom du poste. |
| `rows[].dn` | texte | DN du compte ordinateur. |
| `rows[].objectGuid` | texte | GUID du compte, format `D` minuscule. |
| `rows[].ruleId` | texte | Point le plus grave : `lowDisk`, `neverLoggedOn`, `stale`, `machinePasswordOld`, `diskTight`, `uptime`. |
| `rows[].reason` | texte | Motif affiché, avec la valeur mesurée. |
| `rows[].severity` | texte | `alert` ou `warn`. |
| `rows[].otherReasons` | entier | Autres points d’attention du même poste. |
| `rows[].lastSeenAt` | date-heure ou `null` | Dernière réponse au relevé de présence (ping) ; `null` si aucune réponse n’est enregistrée : poste jamais relevé, ou ping filtré alors que le poste répond à WMI (il peut donc avoir un inventaire). La page affiche « aucune réponse au ping », jamais « jamais vu ». |

Ordre : gravité (`alert` puis `warn`), puis ordre des règles ci-dessus, puis valeur mesurée la plus grave (espace
libre croissant, ancienneté décroissante), puis nom (ordinal). Un poste n’apparaît qu’une fois, avec son point le plus
grave. Les règles et seuils sont ceux de Domenia 1 (§ 4.8).

`recentOperations` :

| Champ | Type | Contenu |
|---|---|---|
| `total` | entier | Entrées disponibles dans le journal. |
| `rows[].label` | texte | Libellé de l’opération et son résultat. |
| `rows[].at` | date-heure | Fin de l’opération. |
| `rows[].tone` | texte | `ok`, `warn`, `alert` ou `info`. |

Au plus 6 lignes, la plus récente d’abord.

### 4.8 Règles, seuils et tons

Seuils par défaut (`DashboardPolicy`, repris des règles de santé de Domenia 1, `Domenia-HealthRules.Model.ps1`) :

| Seuil | Valeur | Origine |
|---|---|---|
| Âge maximal d’un relevé de présence ou d’inventaire | 30 jours | `ObservationMaxAgeDays` |
| Mesure grisée au-delà de | 7 jours | FI-04 |
| Mots de passe expirant | 7 jours | demande de l’Accueil |
| Disque critique | moins de 10 % libre | `DiskFreeAlert` |
| Disque à surveiller | moins de 20 % libre | `DiskFreeWarn` |
| Sans redémarrage | plus de 30 jours | `UptimeDays` |
| Sans connexion AD | plus de 90 jours (`lastLogonTimestamp`, à 14 jours près) | `StaleDays` |
| Mot de passe machine ancien | plus de 60 jours (`pwdLastSet`) | `PasswordDays` |

| Widget | `tone` du widget | `delta.tone` |
|---|---|---|
| `workstationsOnline` | `info` (une absence de réponse n’est jamais un verdict) | `info` |
| `activeAccounts` | `info` | `info` |
| `lockedAccounts` | `alert` si valeur > 0, sinon `ok` | hausse `alert`, baisse `ok`, stable `info` |
| `passwordsExpiring` | `warn` si valeur > 0, sinon `ok` | hausse `warn`, baisse `ok`, stable `info` |
| `diskAlerts` | `alert` si critique > 0, sinon `warn` si serré > 0, sinon `ok` | hausse `alert`, baisse `ok`, stable `info` |
| `osDistribution` | `info` | — |
| `workstationActivity` | `info` | — |
| `measureFreshness` | `ok` si ≥ 90 %, `warn` si ≥ 60 %, sinon `alert` | — |
| `watchlist` | `alert` si une ligne `alert`, sinon `warn` si une ligne, sinon `ok` ; `info` au lieu de `ok` sans relevé d’inventaire de moins de 30 jours (disques et redémarrages non évalués, le `detail` le dit) | — |
| `recentOperations` | `info` | — |

Dans tous les cas, `tone` vaut `off` si le widget est désactivé, sans mesure ou périmé (`stale`).

Définitions des valeurs :

- **Postes en ligne** : comptes ordinateur activés du périmètre dont le dernier relevé de présence (ping) a moins de
  30 jours et a répondu. « Sans réponse » : relevé récent sans réponse. « Non vérifié » : aucun relevé de moins de
  30 jours.
- **Comptes actifs** : objets `user` (catégorie `person`, hors ordinateurs) sans le bit 0x2 de `userAccountControl`.
- **Comptes verrouillés** : comptes actifs dont `msDS-User-Account-Control-Computed` porte le bit 0x10. Un
  `lockoutTime` non nul sans ce calcul lisible va dans `toCheck`, jamais dans `locked`.
- **Mots de passe expirant** : comptes actifs, sans `DONT_EXPIRE_PASSWORD` (0x10000), dont
  `msDS-UserPasswordExpiryTimeComputed` tombe dans ]maintenant ; maintenant + 7 jours]. Expiré : date ≤ maintenant
  ou bit 0x800000. `pwdLastSet` = 0 : « à changer à la prochaine connexion ».
- **Alertes disque** : postes actifs du périmètre avec un relevé d’inventaire de moins de 30 jours et moins de 10 %
  libre sur C:. Un disque de taille nulle ou illisible est « sans relevé », jamais « plein ».
- **Activité** : postes distincts ayant répondu au relevé de présence chaque jour (instantanés quotidiens locaux).
- **Fraîcheur** : âge du dernier relevé de présence de chaque poste actif du périmètre.

`measuredAt` : date de la dernière lecture de l’annuaire pour la famille « annuaire », relevé le plus récent pour les
familles « présence » et « inventaire », la plus ancienne des familles utilisées pour `watchlist`, l’entrée la plus
récente pour `recentOperations`, l’instant du calcul pour `workstationActivity`.

---

## 5. `dashboard.summary`

Tous les widgets de l’Accueil, calculés à partir de la **base locale** (en simulation : de l’annuaire fictif en
mémoire). Ne déclenche **aucune** lecture d’annuaire ni sonde réseau : c’est `dashboard.widget.refresh` qui remesure.
Le bouton « Tout actualiser » appelle `dashboard.widget.refresh` pour chaque widget actif, puis `dashboard.summary`.

- **Classe** : `LocalRead`.
- **Arguments** : aucun.
- **Erreurs** : `arguments.invalid`, `source.unavailable` (mode annuaire non connecté), `operation.cancelled`.

### Résultat

| Champ | Type | Contenu |
|---|---|---|
| `generatedAt` | date-heure | Instant du calcul (horloge du moteur). |
| `scope` | objet | OU de travail des widgets de postes : `dn`, `label`, `subtree`. |
| `store.lastReadAt` | date-heure ou `null` | Dernière lecture de l’annuaire dans la base locale (« Base locale lue il y a 12 min »). En simulation, date fictive de lecture de l’annuaire fictif (référence − 12 min, `SIMULATION.md` § 4.2), que la page affiche « Annuaire fictif lu il y a 12 min » : la base locale n’est jamais ouverte et la page ne la nomme pas (onglet « Données fictives », « Depuis l’annuaire fictif en mémoire »). |
| `store.objects` | entier | Objets d’annuaire dans la base. |
| `store.complete` | booléen | `false` si la dernière lecture s’est arrêtée à sa limite. |
| `widgets` | objet | Les 10 widgets de la liste fermée, clés dans l’ordre du § 4.1, désactivés compris. |

### Exemple complet (simulation, graine par défaut, référence `2026-10-21T16:26:00Z`, fuseau de Paris)

```json
{
  "generatedAt": "2026-10-21T16:26:04Z",
  "scope": { "dn": "OU=Postes,DC=example,DC=local", "label": "Postes", "subtree": true },
  "store": { "lastReadAt": "2026-10-21T16:14:00Z", "objects": 1826, "complete": true },
  "widgets": {
    "workstationsOnline": {
      "id": "workstationsOnline",
      "kind": "kpi",
      "title": "Postes en ligne",
      "scopeLabel": "OU Postes",
      "enabled": true,
      "tone": "info",
      "measuredAt": "2026-10-21T15:58:00Z",
      "stale": false,
      "detail": "Dernier relevé de présence de moins de 30 jours. Une absence de réponse ne prouve pas que le poste est éteint.",
      "data": {
        "value": 287,
        "total": 412,
        "unit": "postes",
        "delta": { "value": 9, "period": "P7D", "label": "+9 sur 7 jours", "tone": "info" },
        "history": [
          { "date": "2026-10-08", "value": 279 }, { "date": "2026-10-09", "value": 268 },
          { "date": "2026-10-10", "value": 58 },  { "date": "2026-10-11", "value": 52 },
          { "date": "2026-10-12", "value": 284 }, { "date": "2026-10-13", "value": 291 },
          { "date": "2026-10-14", "value": 278 }, { "date": "2026-10-15", "value": 289 },
          { "date": "2026-10-16", "value": 271 }, { "date": "2026-10-17", "value": 63 },
          { "date": "2026-10-18", "value": 55 },  { "date": "2026-10-19", "value": 293 },
          { "date": "2026-10-20", "value": 296 }, { "date": "2026-10-21", "value": 287 }
        ],
        "breakdown": [
          { "key": "online", "label": "En ligne", "value": 287, "tone": "ok" },
          { "key": "noAnswer", "label": "Sans réponse", "value": 98, "tone": "warn" },
          { "key": "notChecked", "label": "Non vérifié", "value": 27, "tone": "off" }
        ]
      }
    },
    "activeAccounts": {
      "id": "activeAccounts",
      "kind": "kpi",
      "title": "Comptes actifs",
      "scopeLabel": "Domaine example.local",
      "enabled": true,
      "tone": "info",
      "measuredAt": "2026-10-21T16:14:00Z",
      "stale": false,
      "detail": "Comptes utilisateurs activés de tout le domaine (userAccountControl).",
      "data": {
        "value": 1186,
        "total": null,
        "unit": "comptes",
        "delta": { "value": 8, "period": "P7D", "label": "+8 sur 7 jours", "tone": "info" },
        "history": [
          { "date": "2026-10-08", "value": 1172 }, { "date": "2026-10-09", "value": 1172 },
          { "date": "2026-10-10", "value": 1172 }, { "date": "2026-10-11", "value": 1172 },
          { "date": "2026-10-12", "value": 1175 }, { "date": "2026-10-13", "value": 1176 },
          { "date": "2026-10-14", "value": 1178 }, { "date": "2026-10-15", "value": 1178 },
          { "date": "2026-10-16", "value": 1179 }, { "date": "2026-10-17", "value": 1179 },
          { "date": "2026-10-18", "value": 1179 }, { "date": "2026-10-19", "value": 1183 },
          { "date": "2026-10-20", "value": 1185 }, { "date": "2026-10-21", "value": 1186 }
        ],
        "breakdown": [
          { "key": "enabled", "label": "Actifs", "value": 1186, "tone": "ok" },
          { "key": "disabled", "label": "Désactivés", "value": 72, "tone": "off" }
        ]
      }
    },
    "lockedAccounts": {
      "id": "lockedAccounts",
      "kind": "kpi",
      "title": "Comptes verrouillés",
      "scopeLabel": "Domaine example.local",
      "enabled": true,
      "tone": "alert",
      "measuredAt": "2026-10-21T16:14:00Z",
      "stale": false,
      "detail": "Verrouillage calculé par le contrôleur (msDS-User-Account-Control-Computed), comptes actifs.",
      "data": {
        "value": 7,
        "total": null,
        "unit": "comptes",
        "delta": { "value": 4, "period": "P7D", "label": "+4 sur 7 jours", "tone": "alert" },
        "history": [
          { "date": "2026-10-08", "value": 4 }, { "date": "2026-10-09", "value": 6 },
          { "date": "2026-10-10", "value": 1 }, { "date": "2026-10-11", "value": 0 },
          { "date": "2026-10-12", "value": 9 }, { "date": "2026-10-13", "value": 5 },
          { "date": "2026-10-14", "value": 3 }, { "date": "2026-10-15", "value": 6 },
          { "date": "2026-10-16", "value": 4 }, { "date": "2026-10-17", "value": 0 },
          { "date": "2026-10-18", "value": 1 }, { "date": "2026-10-19", "value": 11 },
          { "date": "2026-10-20", "value": 8 }, { "date": "2026-10-21", "value": 7 }
        ],
        "breakdown": [
          { "key": "locked", "label": "Verrouillés", "value": 7, "tone": "alert" },
          { "key": "toCheck", "label": "À vérifier", "value": 0, "tone": "off" }
        ]
      }
    },
    "passwordsExpiring": {
      "id": "passwordsExpiring",
      "kind": "kpi",
      "title": "Mots de passe expirant sous 7 jours",
      "scopeLabel": "Domaine example.local",
      "enabled": true,
      "tone": "warn",
      "measuredAt": "2026-10-21T16:14:00Z",
      "stale": false,
      "detail": "Expiration calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed), comptes actifs.",
      "data": {
        "value": 23,
        "total": null,
        "unit": "comptes",
        "delta": { "value": -1, "period": "P7D", "label": "−1 sur 7 jours", "tone": "ok" },
        "history": [
          { "date": "2026-10-08", "value": 19 }, { "date": "2026-10-09", "value": 21 },
          { "date": "2026-10-10", "value": 21 }, { "date": "2026-10-11", "value": 22 },
          { "date": "2026-10-12", "value": 18 }, { "date": "2026-10-13", "value": 20 },
          { "date": "2026-10-14", "value": 24 }, { "date": "2026-10-15", "value": 22 },
          { "date": "2026-10-16", "value": 23 }, { "date": "2026-10-17", "value": 25 },
          { "date": "2026-10-18", "value": 25 }, { "date": "2026-10-19", "value": 21 },
          { "date": "2026-10-20", "value": 22 }, { "date": "2026-10-21", "value": 23 }
        ],
        "breakdown": [
          { "key": "expiring", "label": "Expirent sous 7 jours", "value": 23, "tone": "warn" },
          { "key": "expired", "label": "Déjà expirés", "value": 11, "tone": "alert" },
          { "key": "mustChange", "label": "À changer à la prochaine connexion", "value": 4, "tone": "info" },
          { "key": "neverExpires", "label": "N’expirent jamais", "value": 16, "tone": "off" }
        ]
      }
    },
    "diskAlerts": {
      "id": "diskAlerts",
      "kind": "kpi",
      "title": "Alertes disque",
      "scopeLabel": "OU Postes",
      "enabled": true,
      "tone": "alert",
      "measuredAt": "2026-10-21T15:31:00Z",
      "stale": false,
      "detail": "Moins de 10 % libre sur C: · 371 postes relevés sur 412.",
      "data": {
        "value": 9,
        "total": null,
        "unit": "postes",
        "delta": { "value": -1, "period": "P7D", "label": "−1 sur 7 jours", "tone": "ok" },
        "history": [
          { "date": "2026-10-08", "value": 7 }, { "date": "2026-10-09", "value": 7 },
          { "date": "2026-10-10", "value": 7 }, { "date": "2026-10-11", "value": 7 },
          { "date": "2026-10-12", "value": 8 }, { "date": "2026-10-13", "value": 8 },
          { "date": "2026-10-14", "value": 10 }, { "date": "2026-10-15", "value": 9 },
          { "date": "2026-10-16", "value": 9 }, { "date": "2026-10-17", "value": 9 },
          { "date": "2026-10-18", "value": 9 }, { "date": "2026-10-19", "value": 8 },
          { "date": "2026-10-20", "value": 9 }, { "date": "2026-10-21", "value": 9 }
        ],
        "breakdown": [
          { "key": "critical", "label": "Moins de 10 % libre", "value": 9, "tone": "alert" },
          { "key": "tight", "label": "10 à 20 % libre", "value": 17, "tone": "warn" },
          { "key": "healthy", "label": "20 % et plus", "value": 345, "tone": "ok" },
          { "key": "unknown", "label": "Sans relevé", "value": 41, "tone": "off" }
        ]
      }
    },
    "osDistribution": {
      "id": "osDistribution",
      "kind": "distribution",
      "title": "Systèmes d’exploitation",
      "scopeLabel": "OU Postes",
      "enabled": true,
      "tone": "info",
      "measuredAt": "2026-10-21T16:14:00Z",
      "stale": false,
      "detail": "Attributs operatingSystem et operatingSystemVersion des comptes ordinateur activés.",
      "data": {
        "total": 412,
        "unit": "postes",
        "centerText": "412 postes",
        "segments": [
          { "key": "w11-24h2", "label": "Windows 11 24H2", "value": 223, "percent": 54.1, "members": [] },
          { "key": "w11-23h2", "label": "Windows 11 23H2", "value": 96, "percent": 23.3, "members": [] },
          { "key": "w11-25h2", "label": "Windows 11 25H2", "value": 58, "percent": 14.1, "members": [] },
          { "key": "w10-22h2", "label": "Windows 10 22H2", "value": 23, "percent": 5.6, "members": [] },
          { "key": "autres", "label": "Autres", "value": 12, "percent": 2.9, "members": ["Windows 10 LTSC 2021"] }
        ],
        "lead": { "label": "Windows 11 24H2", "percent": 54.1 }
      }
    },
    "workstationActivity": {
      "id": "workstationActivity",
      "kind": "series",
      "title": "Activité des postes · 7 jours",
      "scopeLabel": "OU Postes",
      "enabled": true,
      "tone": "info",
      "measuredAt": "2026-10-21T16:26:04Z",
      "stale": false,
      "detail": "Postes distincts ayant répondu au relevé de présence, par jour. Aujourd’hui : journée en cours.",
      "data": {
        "unit": "postes",
        "max": 312,
        "points": [
          { "date": "2026-10-15", "label": "jeu.", "value": 304, "partial": false },
          { "date": "2026-10-16", "label": "ven.", "value": 287, "partial": false },
          { "date": "2026-10-17", "label": "sam.", "value": 71, "partial": false },
          { "date": "2026-10-18", "label": "dim.", "value": 64, "partial": false },
          { "date": "2026-10-19", "label": "lun.", "value": 309, "partial": false },
          { "date": "2026-10-20", "label": "mar.", "value": 312, "partial": false },
          { "date": "2026-10-21", "label": "mer.", "value": 287, "partial": true }
        ]
      }
    },
    "measureFreshness": {
      "id": "measureFreshness",
      "kind": "gauge",
      "title": "Fraîcheur des mesures",
      "scopeLabel": "OU Postes",
      "enabled": true,
      "tone": "warn",
      "measuredAt": "2026-10-21T15:58:00Z",
      "stale": false,
      "detail": "Postes actifs dont le dernier relevé de présence date de moins de 7 jours.",
      "data": {
        "percent": 84.0,
        "fresh": 346,
        "total": 412,
        "freshDays": 7,
        "breakdown": [
          { "key": "recent", "label": "Moins de 7 jours", "value": 346, "tone": "ok" },
          { "key": "aging", "label": "7 à 30 jours", "value": 39, "tone": "warn" },
          { "key": "expired", "label": "Plus de 30 jours", "value": 15, "tone": "alert" },
          { "key": "never", "label": "Jamais relevé", "value": 12, "tone": "off" }
        ]
      }
    },
    "watchlist": {
      "id": "watchlist",
      "kind": "list",
      "title": "Postes à surveiller",
      "scopeLabel": "OU Postes",
      "enabled": true,
      "tone": "alert",
      "measuredAt": "2026-10-21T15:31:00Z",
      "stale": false,
      "detail": "63 postes avec au moins un point d’attention, du plus grave au moins grave.",
      "data": {
        "total": 63,
        "shown": 6,
        "rows": [
          { "name": "PC-LYO-0031", "dn": "CN=PC-LYO-0031,OU=Lyon,OU=Postes,DC=example,DC=local", "objectGuid": "3f2a9c41-7b0e-4d6a-9e15-0c4b8d2f6a17", "ruleId": "lowDisk", "reason": "Disque C presque plein : 3,1 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-21T15:58:00Z" },
          { "name": "PT-PAR-0118", "dn": "CN=PT-PAR-0118,OU=Paris,OU=Postes,DC=example,DC=local", "objectGuid": "8d41e0b2-55c9-4f3e-a2d7-61f09b3c4e88", "ruleId": "lowDisk", "reason": "Disque C presque plein : 4,0 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-21T15:47:00Z" },
          { "name": "PC-MRS-0007", "dn": "CN=PC-MRS-0007,OU=Marseille,OU=Postes,DC=example,DC=local", "objectGuid": "c07b5e13-2a8f-4b91-8d3c-9e6a14f702d5", "ruleId": "lowDisk", "reason": "Disque C presque plein : 5,2 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-20T14:12:00Z" },
          { "name": "PC-PAR-0142", "dn": "CN=PC-PAR-0142,OU=Paris,OU=Postes,DC=example,DC=local", "objectGuid": "5ae9d270-1c4b-4e8f-b6a0-27d38c91fe04", "ruleId": "lowDisk", "reason": "Disque C presque plein : 6,4 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-21T15:52:00Z" },
          { "name": "PT-LIL-0012", "dn": "CN=PT-LIL-0012,OU=Lille,OU=Postes,DC=example,DC=local", "objectGuid": "91c6f8a3-6d2e-4a07-9b54-e80f3d1a2c69", "ruleId": "lowDisk", "reason": "Disque C presque plein : 7,7 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": null },
          { "name": "PC-BDX-0021", "dn": "CN=PC-BDX-0021,OU=Bordeaux,OU=Postes,DC=example,DC=local", "objectGuid": "e4b0137c-9f5a-4c2d-8e61-a3d75b0c9f12", "ruleId": "lowDisk", "reason": "Disque C presque plein : 8,3 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-19T09:58:00Z" }
        ]
      }
    },
    "recentOperations": {
      "id": "recentOperations",
      "kind": "timeline",
      "title": "Dernières opérations",
      "scopeLabel": "Session",
      "enabled": true,
      "tone": "info",
      "measuredAt": "2026-10-21T16:14:00Z",
      "stale": false,
      "detail": "Journal fictif de la simulation, les plus récentes d’abord.",
      "data": {
        "total": 14,
        "rows": [
          { "label": "Lecture de l’annuaire : 1 826 objets", "at": "2026-10-21T16:14:00Z", "tone": "ok" },
          { "label": "Relevé de présence de l’OU Paris : 158 en ligne sur 186", "at": "2026-10-21T15:58:00Z", "tone": "ok" },
          { "label": "Relevé d’inventaire de l’OU Lyon : 74 postes sur 82", "at": "2026-10-21T15:31:00Z", "tone": "ok" },
          { "label": "Diagnostic de verrouillage : Camille Bernard", "at": "2026-10-21T14:47:00Z", "tone": "warn" },
          { "label": "Lecture BitLocker refusée pour l’OU Marseille", "at": "2026-10-21T13:05:00Z", "tone": "alert" },
          { "label": "Recherche « dupont » : 12 résultats", "at": "2026-10-21T12:40:00Z", "tone": "info" }
        ]
      }
    }
  }
}
```

Ce qui est **contractuel** dans cet exemple : la forme, les noms, les types, et les chiffres du jour que doit produire
la graine par défaut (valeurs, totaux, ventilations, segments, `fresh`, `total` de la liste, `store.objects`), vérifiés
par les tests du § 8 de `SIMULATION.md`. Ce qui est **illustratif** : les heures, les GUID, les noms de postes de la
liste, les valeurs passées de `history` et de `points` (tirées de la graine, avec des creux le week-end) et donc les
`delta`.

---

## 6. `dashboard.widget.refresh`

Remesure un widget, à la demande explicite de l’opérateur (bouton « Actualiser ce widget », ou « Tout actualiser »).
Renvoie le widget recalculé, **même forme** que `dashboard.summary.widgets[id]`.

- **Classe** : `NetworkRead`.
- **Arguments** : `{ "id": "lockedAccounts" }` — `id` texte obligatoire de la liste fermée ; aucune autre propriété.
- **Effet par famille** :

| Famille | Mode annuaire | Simulation |
|---|---|---|
| annuaire | Lecture des attributs du widget, enregistrée dans la base locale. | Relecture de l’annuaire fictif : valeurs inchangées, `measuredAt` = maintenant. |
| présence | Relevé de présence borné à l’OU de travail (jamais la racine du domaine), budgets du moteur. | Nouvelle manche de présence déterministe (`SIMULATION.md` § 5.3) ; seuls les postes de l’OU de travail sont relevés. |
| inventaire | Relevé WMI borné à l’OU de travail. | Relecture de l’inventaire fictif : valeurs inchangées, dates de relevé des postes de l’OU de travail = maintenant. |
| calcul local | Recalcul depuis la base locale, sans réseau. | Recalcul depuis l’état en mémoire. |

- Une actualisation peut changer d’autres widgets qui partagent sa mesure (une manche de présence change aussi
  `measureFreshness`, `workstationActivity` et `watchlist`) : ils sont à jour au prochain `dashboard.summary`.
- Deux actualisations simultanées sont exécutées l’une après l’autre ; aucune n’est refusée pour cette raison.
- Chaque actualisation réussie ajoute une entrée au journal : « Actualisation : *titre du widget* ».
- En simulation, la réponse arrive après un délai réaliste de 400 à 900 ms, pour toutes les familles (calcul local
  compris), annulable. Le délai est déterministe : la *n*-ième actualisation de la session attend toujours la même durée
  pour une graine donnée (les actualisations passent l’une après l’autre ; les lectures de `dashboard.summary` ont leur
  propre suite de délais, de 120 à 250 ms).

**Erreurs**

| Code | Message | Cause |
|---|---|---|
| `arguments.invalid` | Arguments invalides : … | `args` non objet, `id` absent ou non texte, propriété en trop. |
| `widget.unknown` | Widget inconnu : rien n’a été lu. | `id` hors de la liste fermée. |
| `widget.disabled` | Ce widget est désactivé : aucune mesure n’est faite. Réactivez « Mesure active » pour l’actualiser. | Widget désactivé : rien n’est lu, aucune manche n’avance. |
| `scope.tooWide` | Choisissez une OU : la mesure des postes n’est jamais lancée sur tout le domaine. | Famille présence ou inventaire avec la racine du domaine comme périmètre (la simulation applique la même règle). |
| `source.unavailable` | (§ 1.4) | Mode annuaire non connecté. |
| `operation.cancelled` | Opération annulée. | Fermeture de l’application pendant la mesure. |

Exemple de réponse pour `{ "id": "workstationsOnline" }` après une manche de présence :

```json
{
  "id": "workstationsOnline",
  "kind": "kpi",
  "title": "Postes en ligne",
  "scopeLabel": "OU Postes",
  "enabled": true,
  "tone": "info",
  "measuredAt": "2026-10-21T16:27:12Z",
  "stale": false,
  "detail": "Dernier relevé de présence de moins de 30 jours. Une absence de réponse ne prouve pas que le poste est éteint.",
  "data": {
    "value": 291,
    "total": 412,
    "unit": "postes",
    "delta": { "value": 13, "period": "P7D", "label": "+13 sur 7 jours", "tone": "info" },
    "history": [
      { "date": "2026-10-08", "value": 279 }, { "date": "2026-10-09", "value": 268 },
      { "date": "2026-10-10", "value": 58 },  { "date": "2026-10-11", "value": 52 },
      { "date": "2026-10-12", "value": 284 }, { "date": "2026-10-13", "value": 291 },
      { "date": "2026-10-14", "value": 278 }, { "date": "2026-10-15", "value": 289 },
      { "date": "2026-10-16", "value": 271 }, { "date": "2026-10-17", "value": 63 },
      { "date": "2026-10-18", "value": 55 },  { "date": "2026-10-19", "value": 293 },
      { "date": "2026-10-20", "value": 296 }, { "date": "2026-10-21", "value": 291 }
    ],
    "breakdown": [
      { "key": "online", "label": "En ligne", "value": 291, "tone": "ok" },
      { "key": "noAnswer", "label": "Sans réponse", "value": 118, "tone": "warn" },
      { "key": "notChecked", "label": "Non vérifié", "value": 3, "tone": "off" }
    ]
  }
}
```

(Après une manche, tous les postes actifs ont un relevé daté de maintenant, sauf ceux dont la sonde est en erreur ou
refusée, qui restent « Non vérifié ». La valeur 291 est illustrative ; la suite exacte est fixée par la graine.)

---

## 7. `dashboard.widget.setEnabled`

Active ou désactive la mesure d’un widget (interrupteur « Mesure active »). Un widget désactivé **reste au tableau**,
grisé, sans aucune mesure ni appel réseau (demande de David) : `dashboard.summary` le renvoie avec `data` = `null`, et
`dashboard.widget.refresh` le refuse (`widget.disabled`).

- **Classe** : `LocalWrite` (état du moteur, mémorisé dans les préférences locales ; aucune lecture d’annuaire, aucune
  écriture AD). Admise en simulation (fichier `preferences-simulation.json`).
- **Arguments** : `{ "id": "lockedAccounts", "enabled": false }` — `id` texte de la liste fermée, `enabled` booléen ;
  aucune autre propriété.
- **Résultat** : le widget dans son nouvel état, même forme que `dashboard.summary.widgets[id]`.
  - `enabled` = `false` : forme « widget désactivé » du § 4.2.
  - `enabled` = `true` : widget recalculé à partir du **dernier état connu en mémoire**, sans nouvelle lecture ; s’il
    n’a jamais été mesuré, `data` = `null` et `detail` invite à l’actualiser.
- **Idempotente** : redemander l’état courant renvoie le widget sans rien changer ni journaliser.
- Un changement effectif ajoute au journal « Mesure désactivée : *titre* » ou « Mesure réactivée : *titre* ».
- Une actualisation en cours sur un widget qu’on désactive se termine sans être publiée : sa réponse est le widget
  désactivé.
- **Durée de vie** : décision de David du 21/10. Un changement effectif est mémorisé dans les préférences locales (clé
  `dashboard.disabledWidgets` : identifiants des widgets désactivés, dans l’ordre du catalogue) ; au démarrage suivant,
  les widgets reprennent leur état mémorisé dès le premier appel (`dashboard.summary`, `refresh` ou `setEnabled`). Un
  identifiant inconnu est ignoré ; une valeur illisible est tracée et tous les widgets restent actifs. Redemander l’état
  courant n’écrit rien. Si l’écriture échoue, le choix vaut pour la session et le journal le dit (§ 1.3).

**Erreurs**

| Code | Message | Cause |
|---|---|---|
| `arguments.invalid` | Arguments invalides : … | `id` absent ou non texte, `enabled` absent ou non booléen, propriété en trop. |
| `widget.unknown` | Widget inconnu : rien n’a été changé. | `id` hors de la liste fermée. |

Exemple : `{ "id": "lockedAccounts", "enabled": false }` renvoie exactement l’objet « widget désactivé » du § 4.2.

---

## 8. Arborescence des OU : éléments communs

Le panneau d’arborescence (choix de l’OU de travail) lit les OU du domaine de la session. Seuls les objets
`organizationalUnit` sont listés : les conteneurs (`CN=Users`, `CN=Computers`, `CN=Builtin`) ne le sont jamais ; une OU
placée sous un conteneur est rattachée à l’OU la plus proche au-dessus d’elle, sinon à la racine.

Élément d’OU (forme commune à `directory.ou.children` et `directory.ou.search`) :

| Champ | Type | Contenu |
|---|---|---|
| `dn` | texte | DN de l’OU, tel que l’annuaire l’écrit (échappements RFC 4514 compris) ; réutilisable tel quel dans les arguments. |
| `name` | texte | Nom de l’OU (`name`, accents conservés). |
| `path` | texte | Chemin lisible du domaine à l’OU : `example.local › Postes › Paris` (séparateur : espace insécable, `›`, espace). |
| `hasChildren` | booléen | L’OU contient au moins une sous-OU. |
| `counts.users` | entier | Utilisateurs de l’OU **et de ses sous-OU**, activés ou non. |
| `counts.computers` | entier | Ordinateurs, même règle. |
| `counts.groups` | entier | Groupes, même règle. |

Ordre : nom, dans l’ordre alphabétique français sans casse (indépendant de la culture du poste), puis DN.

---

## 9. `directory.ou.children`

OU enfants d’une OU, ou de la racine du domaine.

- **Classe** : `LocalRead` en simulation (annuaire fictif en mémoire), `NetworkRead` en mode annuaire (lecture de
  l’arborescence à l’ouverture ou au dépliage du panneau : geste explicite, un niveau à la fois).
- **Arguments** : `{ "dn": null }` — `dn` texte ou `null` ; absent ou `null` désigne la racine du domaine ; aucune autre
  propriété. Le DN de la racine elle-même (`DC=example,DC=local`, casse et échappements ignorés) est admis.
- **Erreurs** : `arguments.invalid` (`dn` non texte, vide, mal formé, plus de 2 048 caractères, propriété en trop, `args`
  non objet), `ou.unknown` (DN bien formé qui n’est ni la racine ni une OU du domaine), `source.unavailable` (mode
  annuaire non connecté), `operation.cancelled`. L’aperçu dans un navigateur (`web/js/mock.js`) applique les mêmes
  contrôles, dans le même ordre et avec les mêmes textes.
- **Simulation** : délai réaliste de 60 à 160 ms, annulable (sous-suite `latency/screen/tree`).

### Résultat

| Champ | Type | Contenu |
|---|---|---|
| `parent` | objet | `{ dn, name, path }` de l’OU demandée ; pour la racine : DN de la racine, `name` = `path` = nom DNS du domaine. |
| `children` | tableau | Éléments d’OU (§ 8) des OU enfants directes ; `[]` pour une feuille. |

### Exemple (simulation, `{ "dn": null }`)

```json
{
  "parent": { "dn": "DC=example,DC=local", "name": "example.local", "path": "example.local" },
  "children": [
    { "dn": "OU=Comptes à privilèges,DC=example,DC=local", "name": "Comptes à privilèges", "path": "example.local › Comptes à privilèges", "hasChildren": false, "counts": { "users": 6, "computers": 0, "groups": 0 } },
    { "dn": "OU=Comptes de service,DC=example,DC=local", "name": "Comptes de service", "path": "example.local › Comptes de service", "hasChildren": false, "counts": { "users": 13, "computers": 0, "groups": 0 } },
    { "dn": "OU=Domain Controllers,DC=example,DC=local", "name": "Domain Controllers", "path": "example.local › Domain Controllers", "hasChildren": false, "counts": { "users": 0, "computers": 2, "groups": 0 } },
    { "dn": "OU=Groupes,DC=example,DC=local", "name": "Groupes", "path": "example.local › Groupes", "hasChildren": true, "counts": { "users": 0, "computers": 0, "groups": 58 } },
    { "dn": "OU=Postes,DC=example,DC=local", "name": "Postes", "path": "example.local › Postes", "hasChildren": true, "counts": { "users": 0, "computers": 431, "groups": 0 } },
    { "dn": "OU=Serveurs,DC=example,DC=local", "name": "Serveurs", "path": "example.local › Serveurs", "hasChildren": true, "counts": { "users": 0, "computers": 18, "groups": 0 } },
    { "dn": "OU=Utilisateurs,DC=example,DC=local", "name": "Utilisateurs", "path": "example.local › Utilisateurs", "hasChildren": true, "counts": { "users": 1236, "computers": 0, "groups": 0 } }
  ]
}
```

`{ "dn": "OU=Postes,DC=example,DC=local" }` renvoie `Bordeaux` (36 postes), `Lille` (44), `Lyon` (82), `Marseille` (64),
`Paris` (186) et `Quarantaine` (19), chemins `example.local › Postes › Paris`…

---

## 10. `directory.ou.search`

Recherche d’OU par nom ou par chemin, pour le champ de recherche du panneau.

- **Classe** : comme `directory.ou.children`.
- **Arguments** : `{ "text": "secu" }` — `text` texte obligatoire, 100 caractères au plus ; aucune autre propriété.
- **Correspondance** : l’OU est retenue si son **nom ou son chemin** contient le texte, **sans accent ni casse**
  (« securite » trouve « Sécurité », « PARIS » trouve `Utilisateurs › Paris`, ses services et `Postes › Paris`) ; les
  ligatures sont écrites en toutes lettres (« oe ») et l’apostrophe typographique vaut « ' ». Les espaces autour du texte
  sont ignorés ; un texte vide ne trouve rien.
- **Ordre et limite** : par chemin, dans l’ordre alphabétique français ; **au plus 50** éléments. Exactement 50 éléments
  peut vouloir dire que d’autres OU correspondent : la page invite alors à affiner la recherche.
- **Erreurs** : `arguments.invalid`, `source.unavailable`, `operation.cancelled`.

### Résultat

Un **tableau** d’éléments d’OU (§ 8), même forme que `children` ; `[]` si rien ne correspond.

```json
[
  { "dn": "OU=Sécurité,OU=Groupes,DC=example,DC=local", "name": "Sécurité", "path": "example.local › Groupes › Sécurité", "hasChildren": false, "counts": { "users": 0, "computers": 0, "groups": 28 } }
]
```

---

## 11. `session.setScope`

Choisit l’OU de travail (décision de David du 21/10 : « au plus pratique et logique ») : OU globale, choisie dans le
panneau d’arborescence, mémorisée, défaut de toutes les sections sans choix propre (Accueil compris) ; une surcharge par
section viendra ensuite.

- **Classe** : `LocalWrite` (vérification dans l’index local des OU, jamais par le réseau, puis mémorisation dans les
  préférences locales ; aucune écriture AD). Admise en simulation (fichier `preferences-simulation.json`).
- **Arguments** : `{ "dn": "OU=Paris,OU=Postes,DC=example,DC=local", "subtree": true }` — `dn` texte obligatoire (DN bien
  formé, 2 048 caractères au plus), `subtree` booléen obligatoire ; aucune autre propriété.
- **Vérification** : le DN doit être une OU existante du domaine de la session (même règle que `directory.ou.children`),
  ou la racine du domaine (« tout le domaine », toujours avec ses sous-OU : `subtree` est alors forcé à `true`). Avec tout
  le domaine comme OU de travail, les mesures de postes restent refusées (`scope.tooWide`, § 6) : jamais tout le domaine.
- **Effet** : l’OU vaut pour la session dès la réponse (Accueil, `session.info`, sections sans choix propre) et est
  mémorisée **par domaine** dans les préférences (clé `session.workingScope.<SHA-256 du DN de la racine>`, valeur
  `{ dn, subtree }`), comme `Directory.RootOu.<hex>` dans Domenia 1. Un changement effectif ajoute au journal
  « OU de travail : *chemin* » (et « (sans sous-OU) » si `subtree` est faux). Redemander le choix courant n’écrit rien.
- **Démarrage suivant** : l’OU mémorisée pour le domaine de la session est reprise si elle existe encore (vérifiée dans
  l’index local des OU, `IOrganizationalUnitIndex` : mémoire en simulation, base locale en mode annuaire, jamais par le
  réseau ; la racine du domaine est reprise elle aussi, toujours avec ses sous-OU) ; sinon l’OU par défaut de la source s’applique,
  le journal technique trace le code de la raison (jamais le DN) et le journal des opérations affiche
  « OU de travail mémorisée introuvable : périmètre par défaut » (ton `warn`). Une valeur mémorisée pour un autre domaine
  n’est jamais lue.
- **Résultat** : `session.info` à jour (§ 3), dont `scope` et l’étape `scope` des premiers pas.
- **Erreurs** : `arguments.invalid`, `scope.unknown` (OU absente, conteneur), `scope.outsideDomain` (autre domaine),
  `source.unavailable` (mode annuaire non connecté : ni domaine ni index local connus), `operation.cancelled`. L’aperçu
  dans un navigateur suit les mêmes règles, racine du domaine comprise.

Exemple de réponse (extrait) après `{ "dn": "OU=Paris,OU=Postes,DC=example,DC=local", "subtree": true }` :

```json
{
  "connection": { "state": "simulated", "label": "Annuaire simulé" },
  "scope": { "dn": "OU=Paris,OU=Postes,DC=example,DC=local", "label": "Paris", "subtree": true },
  "readOnly": false
}
```

Le `dashboard.summary` suivant porte le même `scope`, `workstationsOnline.data.total` = 186 et `scopeLabel` = `OU Paris`.

---

## 12. Écritures : plan, confirmation, reçu, relecture

Le circuit des écritures ([`WRITES.md`](WRITES.md)) est le même pour tous les écrans : un écran expose une opération de
**lecture** `<écran>.<verbe>.plan` qui renvoie le plan et son jeton ; l’exécution passe toujours par **`write.execute`**,
la seule opération de classe `Write` (§ 1.5) ; les reçus se lisent par `write.receipts.*` (écran Opérations). Rien n’est
jamais rejoué : ni par le moteur, ni par la page, ni au démarrage, ni à partir d’un reçu. En simulation, les écritures ne
changent que la surcouche en mémoire de l’annuaire fictif (décision de David du 21/10) et leurs reçus sont marqués
`simulated` = `true`.

### 12.1 Plan (résultat commun des opérations `<écran>.<verbe>.plan`)

Résultat : `{ "plan": { … }, "token": "…" }`. Le jeton (43 caractères base64url) est à usage unique, lié à l’empreinte du
plan, valable jusqu’à `plan.expiresAt` (5 minutes) ; il n’apparaît dans aucune autre réponse ni dans aucun reçu.

| Champ de `plan` | Type | Contenu |
|---|---|---|
| `id` | texte | Identifiant du plan : 32 caractères hexadécimaux minuscules. |
| `kind` | texte | Type d’écriture, noms pointés en camelCase (`account.unlock`). |
| `title` | texte | Action, pour le titre du panneau (« Déverrouiller le compte »). |
| `label` | texte | Nom de l’opération dans les reçus et les journaux (« Déverrouillage du compte »). |
| `summary` | texte | Ce qui va se passer, en une phrase. |
| `target` | objet | `kind` (`user`, `computer`, `group`, `ou`), `kindLabel` (« Compte utilisateur »), `name`, `dn`, `objectGuid` (format `D` minuscule), `samAccountName` (texte ou `null`). |
| `changes` | tableau | 1 à 64 changements `{ attribute, label, kind, before, after, beforeValue, afterValue }` : `kind` vaut `replace`, `clear`, `add`, `remove`, `move` ou `reset` ; `before` et `after` en clair (texte ou `null`) ; `beforeValue` et `afterValue` valeurs brutes de l’annuaire (texte ou `null`), jamais un secret. |
| `risks` | tableau | Points à vérifier `{ tone, text }`, `tone` = `warn`, `alert` ou `info` ; `[]` si aucun. |
| `confirmation` | objet | `typedNameRequired` (booléen), `typedName` (nom exact à saisir, texte ou `null`), `reason` (phrase). |
| `reversibility` | objet | `reversible` (booléen), `label`, `detail`. |
| `controller` | texte ou `null` | Contrôleur destinataire (celui qui a été lu). |
| `operator` | texte | Compte de la session (`EXAMPLE\j.martin`). |
| `mode` | texte | `simulation` ou `annuaire`. |
| `simulated` | booléen | `true` en simulation. |
| `createdAt`, `expiresAt` | date-heure | Préparation et fin de validité (5 minutes plus tard). |
| `fingerprint` | texte | SHA-256 (64 hexadécimaux) de la forme canonique du plan (`WRITES.md` § 3). |
| `details` | texte | Détails techniques repliés, une ligne par fait (cible, DN, GUID, contrôleur, opérateur, mode, changements, dates, 12 premiers caractères de l’empreinte). |

Refus communs d’un plan : `source.unavailable` (aucun exécuteur de ce type dans ce mode : mode annuaire tant que
`Domenia.Ad` n’est pas branché), `write.targetPending`, `receipt.unavailable` (§ 12.7). Un plan n’écrit rien.

### 12.2 `accounts.unlock.plan`

Plan du déverrouillage d’un compte utilisateur (Domenia 1 FIC-012 : remise à zéro de `lockoutTime`, puis vérification).

- **Classe** : `LocalRead` en simulation, `NetworkRead` en mode annuaire (relecture du compte sur le contrôleur, après le
  geste de l’opérateur).
- **Arguments** : `{ "dn": "CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local" }` — `dn` texte
  obligatoire (DN bien formé, 2 048 caractères au plus, casse et échappements ignorés) ; aucune autre propriété.
- **Règles** : compte avec `lockoutTime` non nul (verrouillé, verrouillage expiré ou « à vérifier » : Domenia 1 efface aussi
  un verrouillage expiré) ; changement unique `lockoutTime` → `0` (`kind` = `clear`) ; saisie du nom (`sAMAccountName`)
  exigée pour un compte protégé (`adminCount` = 1), confirmation simple sinon ; sans retour arrière (aucune compensation,
  comme Domenia 1). Risques : identité du demandeur (verrouillé, avec le nombre d’essais), verrouillage déjà expiré ou non
  confirmé par le contrôleur, compte désactivé, compteur d’essais remis à zéro, mot de passe à changer, compte à privilèges.
- **Erreurs** : `arguments.invalid`, `write.targetUnknown` (« Ce nom distinctif ne désigne aucun compte utilisateur de
  l’annuaire fictif : aucune écriture préparée. » en simulation), `write.nothingToDo` (« Ce compte n’est pas verrouillé :
  aucune écriture à préparer. »), refus communs du § 12.1, `operation.cancelled`.
- **Simulation** : délai réaliste de 90 à 220 ms (`latency/screen/write/plan`).

Exemple (simulation, graine par défaut ; heures, identifiant, empreinte et jeton illustratifs) :

```json
{
  "plan": {
    "id": "5b0e4c1d9a7f42e8b3c6d1a0f9e8d7c6",
    "kind": "account.unlock",
    "title": "Déverrouiller le compte",
    "label": "Déverrouillage du compte",
    "summary": "Camille Bernard pourra de nouveau ouvrir une session : lockoutTime remis à zéro sur DC01.example.local.",
    "target": { "kind": "user", "kindLabel": "Compte utilisateur", "name": "Camille Bernard", "dn": "CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local", "objectGuid": "6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3", "samAccountName": "c.bernard" },
    "changes": [
      { "attribute": "lockoutTime", "label": "Verrouillage", "kind": "clear", "before": "Verrouillé depuis le 21/10/2026 à 18:08", "after": "Déverrouillé", "beforeValue": "134055412800000000", "afterValue": "0" }
    ],
    "risks": [
      { "tone": "warn", "text": "Vérifiez l’identité du demandeur : un verrouillage (5 essais erronés) peut aussi venir d’une tentative d’intrusion ou d’un ancien mot de passe enregistré sur un poste." },
      { "tone": "info", "text": "Le contrôleur remet aussi à zéro le compteur d’essais erronés (5)." }
    ],
    "confirmation": { "typedNameRequired": false, "typedName": null, "reason": "Confirmation simple : compte standard ; ni droit ni mot de passe modifié." },
    "reversibility": { "reversible": false, "label": "Sans retour arrière", "detail": "Un déverrouillage ne se défait pas : le compte ne se verrouille de nouveau qu’après de nouveaux essais erronés. Aucune compensation n’est proposée, comme dans Domenia 1." },
    "controller": "DC01.example.local",
    "operator": "EXAMPLE\\j.martin",
    "mode": "simulation",
    "simulated": true,
    "createdAt": "2026-10-21T16:26:00Z",
    "expiresAt": "2026-10-21T16:31:00Z",
    "fingerprint": "3f2a9c41b7e05d6a8c1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c",
    "details": "Opération : account.unlock\nCible : Compte utilisateur Camille Bernard\n…\nEmpreinte du plan : 3f2a9c41b7e0"
  },
  "token": "q3V0Jx9cR2m8T1wYbZ5nA7eK4hU6sD0fG2iL8pO3vXc"
}
```

### 12.3 `write.execute`

Exécute **une fois** un plan confirmé et renvoie son reçu (forme du § 12.6, avec `details` et `plan`).

- **Classe** : `Write` — seule opération de cette classe, admise par les gardes des deux modes (§ 1.5).
- **Arguments** : `{ "planId": "…", "token": "…", "typedName": null }` — `planId` (32 hexadécimaux) et `token` (43
  caractères base64url) obligatoires ; `typedName` texte (256 caractères au plus) ou `null`, obligatoire et identique au nom
  du plan (casse comprise) quand `confirmation.typedNameRequired` est vrai, ignoré sinon ; aucune autre propriété.
- **Déroulé** (`WRITES.md` § 3) : contrôles du plan et du jeton, nom saisi, jeton consommé (un refus après ce point dépense
  le plan), une écriture à la fois, aucune écriture incertaine sur la cible, préconditions relues, **reçu version 1 écrit
  avant l’envoi** (sans lui rien ne part), envoi unique jamais interrompu, résultat enregistré, relecture de l’objet, reçu
  complété, journal des opérations (« Déverrouillage du compte (simulation) : Camille Bernard · relecture conforme »).
- **Événements** : `write.execute:stage` avec `{ "stage": "checking" | "sending" | "verifying", "label": "…" }` (« Relecture
  de l’objet avant l’envoi », « Reçu enregistré, envoi du changement », « Relecture après l’écriture »), dans cet ordre.
- **Résultat** : une fois le reçu écrit, la réponse est **toujours** un reçu, quelle que soit l’issue : `applied`,
  `noChange` (objet déjà dans l’état demandé : rien envoyé), `notApplied` (refus attendu avant tout changement, `error`
  renseignée), `unknown` (issue inconnue après l’envoi : à vérifier, bloque la cible).
- **Erreurs** (rien n’a été envoyé) : `arguments.invalid`, `write.planUnknown`, `write.tokenUsed`, `write.tokenInvalid`,
  `write.planChanged`, `write.tokenExpired`, `write.confirmationMismatch`, `write.targetPending`, `write.stale`,
  `receipt.unavailable`, `source.unavailable`, `operation.cancelled` (fermeture pendant l’attente d’une autre écriture).
- **Simulation** : préconditions 60 à 140 ms, envoi 280 à 620 ms, relecture 90 à 200 ms (`latency/screen/write/…`).

### 12.4 `write.receipts.list`

Reçus du mode (fichier du mode, plus les versions de la session), **à vérifier d’abord**, puis du plus récent au plus
ancien ; 500 lignes au plus (les reçus à vérifier toujours compris).

- **Classe** : `LocalRead`. **Arguments** : aucun.
- **Erreurs** : `arguments.invalid`, `receipt.unavailable` (reçus illisibles pour l’instant).

| Champ | Type | Contenu |
|---|---|---|
| `total` | entier | Reçus connus. |
| `pending` | entier | Reçus à vérifier (chacun bloque les écritures sur sa cible). |
| `unreadable` | entier | Enregistrements illisibles ignorés. |
| `truncated` | booléen | `true` si des reçus ne sont pas renvoyés (au-delà de 500). |
| `summary` | texte | Phrase de la liste (« Aucune écriture à vérifier. Un reçu conservé ; rien n’est renvoyé automatiquement. »). |
| `receipts` | tableau | Lignes : forme du § 12.6 **sans** `details` ni `plan`. |

### 12.5 `write.receipts.get` et `write.receipts.verify`

- `write.receipts.get` (`LocalRead`) : `{ "id": "…" }` (32 hexadécimaux) → le reçu complet (§ 12.6). Erreurs :
  `arguments.invalid`, `receipt.unknown`, `receipt.unavailable`.
- `write.receipts.verify` (`NetworkRead`, servie en simulation) : `{ "id": "…" }` → relit l’objet du reçu (mémoire en
  simulation, contrôleur en mode annuaire, après le geste de l’opérateur) et renvoie le reçu avec une version de plus
  (`verification`, `verifiedAt`, détail « Relecture »). **Seule une lecture part** : l’écriture n’est jamais renvoyée. Un
  reçu à vérifier tranché par la relecture (`verified` ou `mismatch`) cesse de bloquer sa cible. Erreurs :
  `arguments.invalid`, `receipt.unknown`, `receipt.unavailable`, `source.unavailable`, `operation.cancelled`.

### 12.6 Reçu

| Champ | Type | Contenu |
|---|---|---|
| `id` | texte | Identifiant du reçu (32 hexadécimaux). |
| `kind`, `title`, `label` | texte | Ceux du plan. |
| `target` | objet | Cible du plan (§ 12.1). |
| `at` | date-heure | Dernière version du reçu. |
| `sentAt` | date-heure | Écriture du reçu avant l’envoi. |
| `completedAt` | date-heure ou `null` | Résultat de l’envoi ; `null` tant qu’il manque. |
| `verifiedAt` | date-heure ou `null` | Dernière relecture. |
| `operator`, `controller`, `mode`, `simulated` | | Ceux du plan. |
| `result` | texte | `sent` (envoyée, issue à vérifier : application fermée pendant l’envoi), `applied`, `noChange`, `notApplied`, `unknown`. |
| `resultLabel` | texte | « Envoyée, issue à vérifier », « Appliquée » (« Appliquée (simulation) »), « Déjà faite : rien envoyé », « Non appliquée », « Issue inconnue, à vérifier ». |
| `verification` | texte | `verified`, `mismatch` ou `unknown`. |
| `verificationLabel` | texte | « Vérifiée par relecture », « Écart à la relecture » (« Relue : objet inchangé » après un refus), « Relecture en attente », « Non vérifiée ». |
| `pending` | booléen | `true` si la requête est partie sans issue connue (`sent`, `unknown`) et qu’aucune relecture n’a tranché : le reçu bloque les écritures sur sa cible. |
| `tone` | texte | `ok`, `warn`, `alert` ou `info` (`WRITES.md` § 4.1). |
| `summary` | texte | Phrase pour l’opérateur ; en simulation, elle dit « aucun effet réel ». |
| `error` | objet ou `null` | `{ code, message }` d’un refus ou d’une issue inconnue (`write.outcomeUnknown`). |
| `details` | tableau | `{ label, value }` dans l’ordre : « Préconditions », « Envoi », puis une « Relecture » par relecture. Absent des lignes de la liste. |
| `plan` | objet | Le plan exécuté (§ 12.1, sans jeton). Absent des lignes de la liste. |

Exemple (réponse de `write.execute`, simulation ; extrait) :

```json
{
  "id": "9c8b7a6f5e4d43c2b1a0f9e8d7c6b5a4",
  "kind": "account.unlock",
  "title": "Déverrouiller le compte",
  "label": "Déverrouillage du compte",
  "target": { "kind": "user", "kindLabel": "Compte utilisateur", "name": "Camille Bernard", "dn": "CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local", "objectGuid": "6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3", "samAccountName": "c.bernard" },
  "at": "2026-10-21T16:27:02Z",
  "sentAt": "2026-10-21T16:27:01Z",
  "completedAt": "2026-10-21T16:27:02Z",
  "verifiedAt": "2026-10-21T16:27:02Z",
  "operator": "EXAMPLE\\j.martin",
  "controller": "DC01.example.local",
  "mode": "simulation",
  "simulated": true,
  "result": "applied",
  "resultLabel": "Appliquée (simulation)",
  "verification": "verified",
  "verificationLabel": "Vérifiée par relecture",
  "pending": false,
  "tone": "ok",
  "summary": "Écriture appliquée et vérifiée par relecture. Simulation : annuaire fictif en mémoire, aucun effet réel.",
  "error": null,
  "details": [
    { "label": "Préconditions", "value": "Compte relu sur DC01.example.local : toujours verrouillé, DN et GUID inchangés." },
    { "label": "Envoi", "value": "lockoutTime remis à zéro dans l’annuaire fictif (en mémoire, aucun effet réel), comme le ferait DC01.example.local." },
    { "label": "Relecture", "value": "lockoutTime = 0 relu sur DC01.example.local : compte déverrouillé." }
  ],
  "plan": { "id": "5b0e4c1d9a7f42e8b3c6d1a0f9e8d7c6", "kind": "account.unlock" }
}
```

Stockage (`LocalWrite`) : une ligne JSON par version dans `receipts.jsonl` (mode annuaire) ou `receipts-simulation.jsonl`
(simulation) du dossier de données, ajout atomique ; en mémoire seulement en mode capture et en mode E2E (`WRITES.md` § 4.2).

### 12.7 Codes d’erreur du circuit

| Code | Message | Cause |
|---|---|---|
| `write.planUnknown` | Plan d’écriture inconnu ou expiré : rien n’a été envoyé. Préparez de nouveau l’écriture. | Plan absent de cette session (autre session, ou purgé longtemps après son expiration). |
| `write.tokenUsed` | Ce plan a déjà servi : une écriture ne part qu’une fois et n’est jamais rejouée. Préparez de nouveau l’écriture si besoin. | Second envoi du même plan (double clic, deux pages), ou plan dépensé par un refus. |
| `write.tokenInvalid` | Jeton de confirmation refusé : rien n’a été envoyé. Préparez de nouveau l’écriture. | Jeton d’un autre plan ou inventé ; le plan n’est pas dépensé. |
| `write.planChanged` | Le plan ne correspond plus à son empreinte : rien n’a été envoyé. | Plan modifié après son scellement. |
| `write.tokenExpired` | Confirmation expirée (plan de plus de 5 min) : rien n’a été envoyé. Préparez de nouveau l’écriture pour relire l’objet. | `expiresAt` atteint. |
| `write.confirmationMismatch` | Le nom saisi ne correspond pas à la cible : rien n’a été envoyé. Préparez de nouveau l’écriture. | `typedName` différent du nom exigé (le plan est dépensé). |
| `write.targetPending` | Une écriture précédente sur cet objet reste à vérifier : relisez son reçu dans Opérations avant d’en préparer une autre. | Reçu à vérifier sur la même cible (GUID). |
| `write.stale` | *Raison de l’exécuteur*, qui finit toujours par « Rien n’a été envoyé. » | Préconditions changées depuis le plan (objet déplacé, renommé, supprimé, valeur « avant » différente). |
| `write.nothingToDo` | *Phrase de l’exécuteur* (« Ce compte n’est pas verrouillé : aucune écriture à préparer. »). | Objet déjà dans l’état demandé au moment du plan. |
| `write.targetUnknown` | *Phrase de l’exécuteur* (« Objet introuvable dans l’annuaire : aucune écriture préparée. » par défaut). | DN qui ne désigne pas un objet du type attendu. |
| `write.outcomeUnknown` | Issue inconnue après l’envoi : vérifiez l’objet par une relecture avant toute nouvelle écriture. Rien n’est renvoyé automatiquement. | Gardé sur un reçu `unknown` (`error`), jamais renvoyé comme erreur de l’opération. |
| `receipt.unavailable` | Reçus d’écriture illisibles ou impossibles à enregistrer : rien n’a été envoyé. | Reçu version 1 non écrit (disque plein, droits) ; ou, pour un plan et la liste : « Reçus d’écriture illisibles pour l’instant (fichier verrouillé ou accès refusé) : aucune écriture n’est préparée tant qu’ils ne sont pas relus. » |
| `receipt.unknown` | Reçu introuvable : rien n’a été lu. | Identifiant inconnu. |

Précisions de `arguments.invalid` propres au circuit : « « planId » doit être un identifiant de plan (32 caractères
hexadécimaux). », « « token » doit être un jeton de confirmation. », « « typedName » doit être un texte ou null. »,
« « typedName » doit faire au plus 256 caractères. », « « id » doit être un identifiant de reçu (32 caractères
hexadécimaux). ».
