# Domenia 2 — contrat des opérations du pont

Ce document fixe, opération par opération, ce que la page web peut demander au moteur et la forme **exacte** de la
réponse. Il couvre le shell et la page Accueil : `app.info`, `session.info`, `dashboard.summary`,
`dashboard.widget.refresh` et `dashboard.widget.setEnabled`. La conception du mode simulation qui sert ces opérations
sans Active Directory est dans [`SIMULATION.md`](SIMULATION.md).

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
| `Write` | Écriture AD ou action distante : plan, confirmation, reçu, relecture. **Refusée en simulation** (§ 1.5). |

La classe déclarée est celle du **mode annuaire** (le cas le plus exigeant). En simulation, le même nom d’opération
garde la même classe et les mêmes règles d’admission, même si son gestionnaire ne touche ni réseau ni disque.

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
| `simulation.readOnly` | Écritures désactivées en simulation : aucune écriture tentée. | Toute opération de classe `Write` en simulation, refusée **avant** son gestionnaire. |
| `simulation.unavailable` | Non disponible en simulation : aucune connexion au poste ni à l’annuaire. | Opération `NetworkRead` que l’annuaire fictif ne sert pas, refusée **avant** son gestionnaire. |
| `source.unavailable` | Lecture de l’annuaire indisponible dans cette version : lancez Domenia avec --simulation pour l’essayer sans Active Directory. | Mode annuaire tant que `Domenia.Ad` n’est pas branché. |

Précisions fixes de `arguments.invalid` :

- « cette opération n’en accepte aucun. » — `args` porte des propriétés alors que l’opération n’en prend pas ;
- « un objet JSON est attendu. » — `args` n’est pas un objet ;
- « propriété non admise. » — propriété inconnue ou en double ;
- « « id » est obligatoire et doit être un texte. » ;
- « « enabled » est obligatoire et doit valoir true ou false. ».

Une opération sans argument accepte `args` absent, `null` ou `{}`.

### 1.5 Admission en simulation

En simulation, le dispatcher refuse toute opération de classe `Write` avec `simulation.readOnly`, sans appeler le
gestionnaire. Une opération `NetworkRead` n’est admise que si sa déclaration la marque servie par l’annuaire fictif
(`OperationDefinition.ServedInSimulation`, aujourd’hui `dashboard.widget.refresh` seulement) ; toute autre (outils
distants à venir) est refusée par défaut, sans appeler le gestionnaire, avec `simulation.unavailable` : « Non
disponible en simulation : aucune connexion au poste ni à l’annuaire. » (parité avec `DOMENIA_DEMO_WRITE` et
`DOMENIA_DEMO_UNAVAILABLE` de Domenia 1). Chaque refus du pont (message, opération, admission, arguments) est tracé
dans le journal technique par son code et le nom d’opération déclaré, jamais par le contenu du message.

### 1.6 Récapitulatif

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `app.info` | `Local` | aucun | identité de l’application et mode |
| `session.info` | `Local` | aucun | session, domaine, contrôleur, périmètre, base locale |
| `dashboard.summary` | `LocalRead` | aucun | tous les widgets de l’Accueil |
| `dashboard.widget.refresh` | `NetworkRead` | `{ id }` | le widget remesuré |
| `dashboard.widget.setEnabled` | `Local` | `{ id, enabled }` | le widget dans son nouvel état |

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
| `modeReason` | texte | Pourquoi ce mode : `argument`, `environment`, `notDomainJoined`, `joinStateUnknown`, `domainJoined`, `environmentOptOut` (voir `SIMULATION.md` § 2). |
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
  "banner": "Simulation : annuaire fictif example.local, aucune connexion à Active Directory, aucune écriture possible."
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

---

## 3. `session.info`

État de la session : qui est connecté, à quel domaine et quel contrôleur, sur quel périmètre, avec quels droits
estimés, et l’état de la base locale. Alimente la barre supérieure, le héros (« Bonjour Julien », puces domaine,
contrôleur, OU) et l’onglet « Session » de « Session et vérifications ».

- **Classe** : `Local` (état en mémoire ; aucune lecture réseau).
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
| `account.givenName` | texte ou `null` | Prénom, pour « Bonjour *prénom* » ; `null` → « Bonjour ». |
| `account.dn` | texte ou `null` | DN du compte. |
| `authentication.method` | texte | `none` (simulation), `windowsSession`, `explicitCredentials`. |
| `authentication.protocol` | texte ou `null` | `kerberos`, `ntlm` ou `null` si inconnu. |
| `authentication.label` | texte | Libellé affiché : `Aucune (simulation)`, `Kerberos`, `NTLM`, `Session Windows`. |
| `scope` | objet ou `null` | Branche de travail des widgets de postes : `dn`, `label` (nom de l’OU), `subtree` (booléen). |
| `rights.level` | texte | `read`, `delegated`, `admin` ou `unknown`. |
| `rights.label` | texte | `Lecture`, `Délégués`, `Administration`, `Non évalués`. |
| `rights.estimated` | booléen | Toujours `true` tant que les droits sont déduits des groupes et non vérifiés par l’annuaire. |
| `rights.detail` | texte | Phrase d’explication. |
| `readOnly` | booléen | Lecture seule active. Toujours `true` en simulation. |
| `tasks.running` | entier | Lectures en cours (actualisations de widgets comprises). |
| `tasks.queued` | entier | Lectures en attente. |
| `cache.state` | texte | `fresh` (moins de 24 h), `aging` (1 à 7 jours), `stale` (plus de 7 jours), `empty` (jamais lue). |
| `cache.label` | texte | `À jour`, `À relire bientôt`, `Ancienne`, `Vide`. |
| `cache.lastReadAt` | date-heure ou `null` | Dernière lecture de l’annuaire enregistrée dans la base locale. |
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
    "detail": "Simulation : les droits sont fictifs et aucune écriture n’est possible."
  },
  "readOnly": true,
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
pas d’utilisateurs. Les widgets de postes couvrent l’OU de travail (`session.info.scope`), sous-arborescence comprise.

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
| `rows[].lastSeenAt` | date-heure ou `null` | Dernière réponse au relevé de présence ; `null` si jamais vu. |

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
| `store.lastReadAt` | date-heure ou `null` | Dernière lecture de l’annuaire dans la base locale (« Base locale lue il y a 12 min »). |
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
          { "name": "PC-LYO-0031", "dn": "CN=PC-LYO-0031,OU=Lyon,OU=Postes,DC=example,DC=local", "objectGuid": "3f2a9c41-7b0e-4d6a-9e15-0c4b8d2f6a17", "ruleId": "lowDisk", "reason": "Disque C: presque plein : 3,1 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-21T15:58:00Z" },
          { "name": "PT-PAR-0118", "dn": "CN=PT-PAR-0118,OU=Paris,OU=Postes,DC=example,DC=local", "objectGuid": "8d41e0b2-55c9-4f3e-a2d7-61f09b3c4e88", "ruleId": "lowDisk", "reason": "Disque C: presque plein : 4,0 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-21T15:47:00Z" },
          { "name": "PC-MRS-0007", "dn": "CN=PC-MRS-0007,OU=Marseille,OU=Postes,DC=example,DC=local", "objectGuid": "c07b5e13-2a8f-4b91-8d3c-9e6a14f702d5", "ruleId": "lowDisk", "reason": "Disque C: presque plein : 5,2 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-20T14:12:00Z" },
          { "name": "PC-PAR-0142", "dn": "CN=PC-PAR-0142,OU=Paris,OU=Postes,DC=example,DC=local", "objectGuid": "5ae9d270-1c4b-4e8f-b6a0-27d38c91fe04", "ruleId": "lowDisk", "reason": "Disque C: presque plein : 6,4 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-21T15:52:00Z" },
          { "name": "PT-LIL-0012", "dn": "CN=PT-LIL-0012,OU=Lille,OU=Postes,DC=example,DC=local", "objectGuid": "91c6f8a3-6d2e-4a07-9b54-e80f3d1a2c69", "ruleId": "lowDisk", "reason": "Disque C: presque plein : 7,7 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": null },
          { "name": "PC-BDX-0021", "dn": "CN=PC-BDX-0021,OU=Bordeaux,OU=Postes,DC=example,DC=local", "objectGuid": "e4b0137c-9f5a-4c2d-8e61-a3d75b0c9f12", "ruleId": "lowDisk", "reason": "Disque C: presque plein : 8,3 % libre", "severity": "alert", "otherReasons": 0, "lastSeenAt": "2026-10-19T09:58:00Z" }
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
| présence | Relevé de présence borné à l’OU de travail (jamais la racine du domaine), budgets du moteur. | Nouvelle manche de présence déterministe (`SIMULATION.md` § 5.3). |
| inventaire | Relevé WMI borné à l’OU de travail. | Relecture de l’inventaire fictif : valeurs inchangées, dates de relevé = maintenant. |
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

- **Classe** : `Local` (état en mémoire du moteur ; aucune lecture).
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
- **Durée de vie** : l’état est conservé pendant la session. Sa persistance dans les préférences de l’application
  attend `Domenia.Store` (point ouvert, `SIMULATION.md` § 10).

**Erreurs**

| Code | Message | Cause |
|---|---|---|
| `arguments.invalid` | Arguments invalides : … | `id` absent ou non texte, `enabled` absent ou non booléen, propriété en trop. |
| `widget.unknown` | Widget inconnu : rien n’a été changé. | `id` hors de la liste fermée. |

Exemple : `{ "id": "lockedAccounts", "enabled": false }` renvoie exactement l’objet « widget désactivé » du § 4.2.
