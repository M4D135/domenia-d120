# Écran « Rechercher » — contrat des opérations

Module `SearchOperations` (`src/Domenia.Bridge/Operations/SearchOperations.cs`), écran `search`, route `#/rechercher`.
Règles pures : `src/Domenia.Core/Screens/Search/` (`SearchText`, `SearchMatcher`, `SearchLists`, `SearchViews`,
`SearchSurvey`, `SearchMemoryRules`, `SearchDetails`, `SearchRowFactory`) ; service `SearchService`, mémoire
`SearchMemory`. Lecteur : `ISearchReader`, implémenté en simulation par `SimulatedSearchReader`
(`src/Domenia.Simulation/Screens/`). Parité : `RCH-001` à `RCH-137` (`docs/features.json`). État :
`docs/status/rechercher.json`. Tests : `tests/Domenia.Tests/SearchRulesTests.cs`, `SearchOperationsTests.cs`,
scénarios `tests/e2e/rechercher/*.json` (écrits, non exécutés : décision du 21/10).

## 1. Règles communes

- **Classes.** Les lectures de listes (`search.run`, `search.browse`, `search.view`, `search.more`, `search.revalidate`,
  `search.containers`) sont `LocalRead` en simulation et `NetworkRead` en mode annuaire. Les lectures de la base locale
  (`search.suggest`, `search.preview`, `search.compare`, `search.localQuery`, `search.catalog`, `search.memory`,
  `search.survey.plan`) sont `LocalRead` partout. Les sondes sur geste (`search.survey.run`, `search.recheck`,
  `search.netdiag`, `search.dns.reverse`) sont `NetworkRead` dans les deux modes, servies par l’annuaire fictif
  (`ServedInSimulation`). La mémoire de l’écran (`search.recent.*`, `search.favorite.*`, `search.workspace.*`,
  `search.query.favorite`) est `LocalWrite` (préférences locales). `search.survey.stop` est `Local`. **Aucune écriture
  d’annuaire** n’appartient au module : le déverrouillage proposé par l’aperçu et le menu passe par
  `accounts.unlock.plan` puis `write.execute` (`WRITES.md`), puis `search.revalidate` relit la ligne.
- **Lecture seule par défaut, rien sans geste.** Saisir ne lit jamais l’annuaire : la barre analyse le texte côté page
  (aide, jetons, adresse reconnue) et `search.suggest` ne consulte que la base locale. Entrée, un clic sur une OU, une
  vue ou « Charger la suite » déclenchent une lecture. Aucune lecture du domaine entier sans garde : une recherche sans
  texte est refusée, une étoile seule aussi, le contenu de la racine est une liste bornée qui ne se relève jamais.
- **Arguments.** Objet JSON fermé (propriété inconnue ou en double refusée), DN conformes à la RFC 4514, textes de
  256 caractères au plus (100 pour une suggestion), limites de 1 à 20 000 lignes (100 par défaut), identifiants d’objet
  au format GUID `D`, identifiants de liste, de relevé et de vue personnelle en 32 caractères hexadécimaux, 5 000
  identifiants au plus par appel (500 pour une relecture ou un diagnostic, 2 à 8 pour une comparaison).
- **Listes.** Chaque liste reçoit un `listId` ; le moteur garde les 24 dernières (périmètre, plan, type, dernière clé,
  identifiants déjà chargés). `search.more` lit **seulement** les lignes suivantes (liste doublée, 20 000 au plus) et
  écarte toute ligne déjà chargée ; une liste en cours de lecture refuse une seconde lecture (`search.listBusy`).
- **Absence.** Une liste vide ou incomplète ne prouve jamais qu’un objet n’existe pas : `absence` le dit, avec la portée,
  le type retenu et la limite.
- **Secrets.** Aucun attribut sensible n’est lu ni renvoyé (`unicodePwd`, mots de passe LAPS, clés BitLocker). Les
  copies pour un ticket passent par `maskSecrets` côté page. Aucun compte n’est envoyé aux postes par le diagnostic.
- **Journal.** Chaque recherche, vue, requête locale, relevé et diagnostic laisse une ligne d’information (texte aplati
  à 60 caractères, nombre de résultats, jamais de valeur sensible).

### 1.1 Erreurs propres à l’écran

| Code | Message | Cause |
|---|---|---|
| `search.textInvalid` | (raison du plan : « Saisissez au moins 2 caractères… », « une étoile seule listerait tout le domaine », mots trop courts pour « contient », IPv4 incomplète pour le DNS) | Texte refusé avant toute lecture. |
| `search.listUnknown` | Liste inconnue ou trop ancienne : relancez la recherche. | `listId` absent du registre (24 listes). |
| `search.listComplete` | Liste complète : aucune suite à charger. / Taille demandée hors des bornes… | `search.more` sur une liste complète, ou taille ≤ lignes déjà chargées. |
| `search.listBusy` | Lecture en cours : attendez la fin du chargement. | Deux lectures simultanées de la même liste. |
| `search.viewUnknown` | Vue inconnue : rien n’a été lu. | Vue ou requête locale absente du catalogue. |
| `search.objectUnknown` | Objet inconnu de la base locale : rien n’est affiché. | `search.preview`, `search.recheck` sur un GUID inconnu. |
| `search.compareInvalid` | Comparez de deux à huit objets / des objets d’un même type… | Types mélangés, objet inconnu. |
| `search.surveyRefused` | (motif de l’admission : liste vide, plafond, recherche globale sans terme, racine sans filtre…) | Relevé ou diagnostic refusé avant tout paquet. |
| `search.surveyBusy` | Un relevé de la liste est déjà en cours : arrêtez-le ou attendez sa fin. | Un seul relevé à la fois. |
| `search.notWorkstation` | Cette ligne n’est pas un poste actif : aucune sonde n’est envoyée. | `search.recheck` sur un compte, un groupe, une OU, un poste désactivé. |
| `search.favoriteRefused` | (racine, OU hors du domaine ou inconnue localement, 50 favoris, favori absent) | Favori d’OU refusé. |
| `search.workspaceRefused` | (100 vues, nom déjà pris, bibliothèque trop volumineuse, OU hors du domaine) | Vue personnelle refusée. |
| `search.queryUnknown` / `search.queryRefused` | Requête inconnue / 200 favoris de requête au maximum. | Favori de requête. |

Plus les codes communs d’`OPERATIONS.md` § 1.4 (`arguments.invalid`, `ou.unknown`, `source.unavailable`,
`operation.cancelled`).

## 2. Opérations

| Opération | Classe (simulation / annuaire) | Arguments | Résultat |
|---|---|---|---|
| `search.run` | LocalRead / NetworkRead | `text`, `scope?` (DN de l’OU choisie, sous-OU incluses ; absent = domaine entier), `type?` (`all`, `users`, `computers`, `groups`, `ous`), `limit?`, `match?` (`prefix`, `contains`) | `SearchResult` (§ 3). Une adresse IPv4 ou MAC donne `kind = address` (base locale seulement) ; une IPv4 inconnue ajoute `dns` (offre, rien n’est résolu). |
| `search.browse` | LocalRead / NetworkRead | `dn`, `subtree`, `type?`, `limit?` | `SearchResult` `kind = browse` : contenu de l’OU, sans filtre caché (un terme filtre seulement les lignes chargées, côté page). |
| `search.containers` | LocalRead / NetworkRead | — | Conteneurs de la racine (`Users`, `Computers`, conteneurs système repliés à part) avec leur nombre d’objets. |
| `search.view` | LocalRead / NetworkRead | `id`, `dn?`, `subtree`, `wholeDomain`, `limit?` | `SearchResult` `kind = view` : vue prête sur l’OU choisie (OU de travail par défaut) ou, explicitement, sur tout le domaine (jamais relevable). |
| `search.localQuery` | LocalRead | `id` (`local.*`), `dn`, `subtree`, `verdict?` (`match`, `unknown`, `noMatch`, `all`), `limit?` | `SearchResult` `kind = localQuery` avec `verdicts` (trois totaux, choix affiché) et `verdict` sur chaque ligne. |
| `search.more` | LocalRead / NetworkRead | `listId`, `limit` | `SearchResult` `appended = true` : lignes nouvelles seulement ; `loaded`, `limit`, `continuation` cumulés. |
| `search.suggest` | LocalRead | `text`, `type?` | 8 suggestions au plus (objets de la base locale) ; les recherches récentes sont ajoutées par la page. |
| `search.preview` | LocalRead | `id` | `SearchPreview` : ligne, sections (identité, 80 attributs au plus avec leur date, présence, utilisateur connecté, matériel, adresses, association), source, troncature. |
| `search.compare` | LocalRead | `ids` (2 à 8) | `SearchComparison` : lignes avec valeur et date par objet, nombres de différences, d’égalités et d’inconnus, résumé. |
| `search.catalog` | LocalRead | — | 13 vues prêtes (`ad:<id>`) et 9 requêtes locales (`local:<id>`) avec coût, filtre LDAP, favoris. |
| `search.dns.reverse` | NetworkRead (servie) | `ip` (IPv4) | `{ ip, name, message }` : résolution inverse, 15 s au plus, sur le clic de l’offre. |
| `search.revalidate` | LocalRead / NetworkRead | `ids` (1 à 500) | `{ rows, missing, checkedAt, summary }` : lignes relues ; une absence n’est jamais présentée comme une suppression. |
| `search.survey.plan` | LocalRead | `mode`, `ids`, `context` (§ 4) | `SurveyPlan` : admission, titre, trois lignes de confirmation, durée estimée, cibles exactes, lignes écartées et motif, saisie du nombre au-delà de 100 postes. Rien n’est lu. |
| `search.survey.run` | NetworkRead (servie) | `mode`, `ids`, `context` | `SurveyResult` ; évènements `search.survey.run:progress` après chaque lot (`SurveyProgress` : compteurs et lignes du lot). |
| `search.survey.stop` | Local | `runId` | `{ stopped, message }` : les mesures reçues sont conservées, rien n’est rejoué. |
| `search.recheck` | NetworkRead (servie) | `id` | `SearchRow` relue : un ping et l’utilisateur connecté du seul poste. |
| `search.netdiag` | NetworkRead (servie) | `ids` (1 à 500, 50 postes actifs diagnostiqués au plus) | `NetworkDiagnostic` : ping puis ports 445, 135, 5985, 5986 par poste, lignes écartées, résumé, rapport tabulé. |
| `search.memory` | LocalRead | — | `SearchMemoryState` (§ 5). |
| `search.recent.add` | LocalWrite | `kind` (`search`, `object`), `text`, `type?`, `dn?` | État de la mémoire. |
| `search.recent.clear` | LocalWrite | — | État de la mémoire, récents vidés. |
| `search.favorite.pin` | LocalWrite | `dn`, `name?`, `subtree`, `type?`, `term?` | État ; OU connue localement exigée. |
| `search.favorite.unpin` | LocalWrite | `dn` | État. |
| `search.favorite.move` | LocalWrite | `dn`, `index` | État. |
| `search.workspace.save` | LocalWrite | `name`, `dn`, `subtree`, `type?`, `presence?`, `filter?`, `limit?`, `columnSet?`, `layout?` (`order`, `hidden`, `widths`, `sort`, `density`) | État ; jamais une ligne, un compte ni un droit. |
| `search.workspace.remove` | LocalWrite | `id` | État avec `undo`. |
| `search.workspace.undo` | LocalWrite | — | État, vue rétablie. |
| `search.query.favorite` | LocalWrite | `id` (`ad:…`, `local:…`), `favorite` | État. |

## 3. Résultat commun des listes (`SearchResult`)

| Champ | Sens |
|---|---|
| `listId` | Identifiant de la liste (32 hex), pour `search.more`. |
| `kind` | `search`, `browse`, `view`, `address`, `localQuery`. |
| `scope` | `{ mode (global, ou), dn, label, path, subtree, wholeDomain, chip }` : portée lisible (« Domaine entier », « Dans cette OU : Paris · Sous-OU incluses »). |
| `type`, `text`, `match` | Critères de la lecture. |
| `plan` | `{ kind, valid, reason, hint, notes, tokens, identifier, address, ldapFilter, costly, freeText }` : ce qui a été cherché, le filtre LDAP du mode annuaire, le coût (joker en tête, « contient »). |
| `rows` | Lignes (`SearchRow`) : `id`, `kind`, `kindLabel`, `name`, `display`, `login`, `upn`, `mail`, `description`, `dn`, `container`, `state` (`key`, `label`, `tone`), `flags` (désactivé, verrouillé, à vérifier, mot de passe expiré, à changer, sans expiration, inactif, jamais connecté, expirant, expiré, administration…), `os`, `osVersion`, `lastLogon`, `changed`, `created`, `readAt`, `presence`, `console`, `association`, `address`, `group`, `verdict`, `rank`. |
| `loaded`, `limit`, `complete`, `limitReached` | État de la lecture. |
| `continuation` | `{ allowed, nextLimit, page, jumpLimit, jumpText, reason }` : « Charger la suite » (+ `page` lignes), puis « jusqu’à 1 000 / 5 000 / 20 000 ». |
| `counter`, `absence` | Compteur (« 100 lignes chargées · liste limitée à 100 : affinez ou chargez la suite ») et ce que la liste ne prouve pas. |
| `offer` | Offre « Chercher aussi les noms qui contiennent … » après 5 résultats ou moins d’un texte simple (rien n’est lu avant le clic). |
| `dns` | Offre de résolution inverse d’une IPv4 sans relevé local. |
| `view` | `{ id, name, note, wholeDomain, surveyAllowed, reason }` d’une vue ou d’une requête locale. |
| `verdicts` | `{ match, unknown, noMatch, shown }` d’une requête locale. |
| `sourceLabel`, `readAt`, `appended` | Source (« Annuaire fictif », « Annuaire en direct », « Relevés locaux »), date UTC, page ajoutée. |

Classement d’une recherche (Domenia 1, `Get-DomeniaSearchRank`) : 0 compte, UPN ou courriel exact ; 1 nom exact ;
2 compte, UPN ou courriel qui commence ; 3 mot exact du nom ; 4 nom qui commence ; 5 mot qui commence ; 6 contenu ;
7 autre ; puis nom replié (accents, casse).

## 4. Relevés de la liste et diagnostic

`context` : `{ scope (results, selection), global, hasTerm, wholeDomain, hasFilter, coversList, scopeLabel, subtree,
listLimit }`. Modes : `ping` (« Qui répond ? »), `console` (« Qui est connecté ? »), `analyse` (matériel et requêtes
des widgets), `complete` (relevé léger plus correctifs, démarrage, services, TPM, BIOS, numéro de série ; jamais
`Win32_Product` ni la liste des processus), `unaddressed` (postes sans adresse connue).

Admission (`SearchSurvey.Admit`, Domenia 1 `Get-DomeniaParkAdmission`) : refus d’une liste vide, au-delà du plafond
(500 postes par défaut, 5 000 au plus), d’une recherche globale sans terme, d’une liste de la racine sans autre filtre ;
une sélection partielle est son propre filtre (plafond seulement). Les lignes qui ne sont pas des postes actifs sont
écartées avec leur motif. Au-delà de 100 postes, la page fait saisir le nombre avant l’envoi. Le relevé part une seule
fois, s’arrête sur demande et n’est jamais rejoué ; la page filtre ensuite la liste par issue (en ligne, sans réponse,
erreur) sans nouvelle lecture.

## 5. Mémoire de l’écran

Préférences locales, par domaine (clé `search.<nature>.<empreinte du DN racine>`), jamais de ligne ni de secret :
8 recherches et 8 objets récents (texte aplati à 80 caractères, doublons sans casse retirés), 50 favoris d’OU (libellés
distingués par l’OU parente en cas d’homonymie), 100 vues personnelles (OU, profondeur, type, présence, filtre local,
limite, jeu de colonnes, disposition de la grille) avec annulation du dernier retrait, 200 favoris de requête. Un
échec d’écriture disque est journalisé et rendu dans `warning` ; l’état reste en mémoire.
`SearchMemoryState` : `recents`, `favorites`, `workspaces`, `queryFavorites`, `undo`, `maxFavorites`, `maxWorkspaces`,
`persistent`, `warning`.

## 6. Simulation

- `SimulatedSearchReader` cherche dans l’annuaire fictif vu à travers la surcouche d’écritures (les déverrouillages
  faits dans la session se voient), avec le même plan et le même classement que le mode annuaire.
- Données dérivées de la graine : adresses IPv4 `10.<site>.x.y` relevées à une date, adresses MAC aux préfixes de
  constructeurs (Dell `D4-81-D7`, HP `3C-52-82`, Lenovo `8C-16-45`, VMware `00-50-56`), table DNS inverse, quelques
  réemplois DHCP (deux postes vus avec la même adresse à des dates différentes), utilisateurs connectés, associations
  comptes ↔ postes (`managedBy`, relevés de console).
- Les relevés et revérifications sont mémorisés dans la session (présence, utilisateur connecté, adresse vue) ; la
  présence suit le modèle fictif (`SIMULATION.md` § 5.3 : sondes en erreur, postes muets, week-end).
- Délais réalistes et annulables (`SimulateScreenLatencyAsync("search/…")`, compteurs propres à l’écran) : recherche et
  contenu 40–180 ms, arborescence 40–120 ms, base locale 30–120 ms, relecture 60–160 ms, DNS 200–600 ms, ping
  30–140 ms par poste, utilisateur connecté 220–640 ms, relevé matériel 420–1 100 ms, diagnostic 240–820 ms par poste.

## 7. Mode annuaire

Lectures faites par `Domenia.Ad` (non branché dans cette version : `source.unavailable`), toujours hors du fil de
l’interface, annulables, sur le contrôleur lié à la session. Les budgets sont des plafonds : une lecture tronquée le dit
(`limitReached`, `absence`).

### 7.1 LDAP

| Lecture | Requête | Budget |
|---|---|---|
| `search.run` (texte) | Base = racine ou OU choisie, `SearchScope.Subtree`. Chaque mot : `(|(name=m*)(cn=m*)(sAMAccountName=m*)(displayName=m*)(sn=m*)(givenName=m*)(userPrincipalName=m*)(mail=m*)(dNSHostName=m*))`, tous les mots en `&`, sous le filtre du type (`(&(objectCategory=person)(objectClass=user))`, `(objectCategory=computer)`, `(objectCategory=group)`, `(|(objectClass=organizationalUnit)(objectClass=container))`). Littéraux RFC 4515 (`\2a`, `\28`, `\29`, `\5c`, `\00`) ; un joker saisi reste un joker, un joker en tête est signalé coûteux. | `SizeLimit` = limite + 1 (pour savoir s’il y a une suite), `PageSize` 500, 30 s |
| `search.run` (identifiant collé) | GUID : `(objectGUID=\xx…)` (octets) ; SID : `(objectSid=S-1-…)` ; DN : `(distinguishedName=…)` — recherche exacte, aucun résultat ouvert automatiquement. UPN, `DOMAINE\compte`, nom DNS : filtre exact ajouté en `|` aux mots. | 1 requête |
| `search.run` (syntaxe) | `utilisateur:`, `poste:`, `groupe:` : mots du jeton sous le filtre de son type ; `mail:` : `(|(mail=v*)(proxyAddresses=smtp:v*))`. Aucun filtre caché ; un préfixe inconnu reste du texte. | idem |
| `search.run` (contient) | 1 à 4 mots de 2 caractères au moins : `(|(name=*m*)(displayName=*m*)(sAMAccountName=*m*)(dNSHostName=*m*))` par mot. Lent, annoncé. | idem, 60 s |
| `search.browse` | Base = OU, `OneLevel` ou `Subtree`, filtre du type seul. | idem |
| `search.view` | Filtre de la vue (ex. `(&<personne>(lockoutTime>=1))`, `(&<personne>(userAccountControl:1.2.840.113556.1.4.803:=2))`, `(&(objectCategory=computer)(|(lastLogonTimestamp<=<90 j>)(!(lastLogonTimestamp=*))))`) sur l’OU choisie ; `wholeDomain` seulement sur choix explicite. | idem |
| `search.more` | Même requête triée par `name` (contrôle de tri serveur 1.2.840.113556.1.4.473), reprise après la dernière clé (`(name>=<dernière clé>)` ajouté en `&`), DN déjà chargés écartés. | lignes suivantes seulement |
| `search.revalidate` | `(|(objectGUID=…)…)` par paquets de 40 GUID. | 500 objets |
| `search.containers` | Racine, `OneLevel`, `(objectClass=container)` ; nombre d’objets par conteneur en `OneLevel` (`SizeLimit` 10 000). | 1 + n requêtes |
| `search.suggest`, `search.preview`, `search.compare`, `search.localQuery`, `search.run` (adresse) | Base locale seulement (projection des lectures et relevés datés) : aucune requête LDAP. | — |

Attributs lus pour une ligne : `objectClass`, `objectCategory`, `objectGUID`, `objectSid`, `distinguishedName`, `name`,
`cn`, `sAMAccountName`, `displayName`, `givenName`, `sn`, `userPrincipalName`, `mail`, `description`,
`userAccountControl`, `msDS-User-Account-Control-Computed`, `lockoutTime`, `pwdLastSet`, `accountExpires`,
`lastLogonTimestamp`, `adminCount`, `managedBy`, `groupType`, `operatingSystem`, `operatingSystemVersion`,
`dNSHostName`, `whenCreated`, `whenChanged`. Jamais d’attribut sensible.

### 7.2 Réseau et WMI (sur geste seulement)

| Lecture | Moyen | Budget |
|---|---|---|
| Ping (relevé, revérification, diagnostic) | ICMP vers le `dNSHostName`, lots de 32 échos en parallèle | 1 essai, 1 s par écho |
| Utilisateur connecté | CIM `Win32_ComputerSystem.UserName` (DCOM puis WSMan selon la configuration), console seulement (les sessions RDP ne sont pas recensées) | 4 postes à la fois, 8 s par poste |
| Matériel (analyse) | `Win32_OperatingSystem` (démarrage, mémoire, version), `Win32_LogicalDisk` (`DriveType = 3`), `Win32_ComputerSystem` (modèle), requêtes des widgets | 4 postes à la fois, 15 s par poste |
| Relevé complet | Relevé léger + `Win32_QuickFixEngineering`, services automatiques arrêtés, TPM, BIOS et numéro de série ; jamais `Win32_Product` ni les processus | 4 postes à la fois, 30 s par poste |
| Diagnostic réseau | Ping puis connexion TCP aux ports 445, 135, 5985, 5986 (aucun compte envoyé, aucune donnée lue) | 50 postes, 2 s par port |
| DNS inverse | `Dns.GetHostEntryAsync` sur l’IPv4 de l’offre | 15 s |

Budgets d’un relevé : 500 postes par défaut (5 000 au plus), 120 s sans progrès, 900 s au total ; la revérification
automatique de la liste affichée (180 s) est désactivée par défaut et ne relit que l’annuaire (`search.revalidate`),
jamais les postes. Aucun relevé ne porte sur tout le domaine.

## 8. Écran

- `web/js/pages/rechercher.js` et `web/js/pages/rechercher/*.js` (`bar`, `side`, `results`, `preview`, `actions`,
  `library`, `history`, `text`) ; styles `web/css/pages/rechercher.css` (règles sous `[data-page="rechercher"]`, y
  compris dans les tiroirs et dialogues, marqués `data-page="rechercher"`).
- Paramètres de route : `q` ou `ip` (texte cherché), `portee` (DN de l’OU qui borne la recherche), `type`, `match`
  (`contient`), `limite`, `ou` (DN affiché ou périmètre d’une vue), `sousou` (`0` : enfants directs), `vue` (vue prête),
  `domaine` (`1` : vue sur tout le domaine), `requete` (requête locale), `verdict`, `sel` (`first`, `pc`, `user` ou un
  GUID), `ouvrir` (`requetes`, `vues`, `syntaxe`, `comparer`, `releve`, `menu`, `diag`, `historique`).
- Clavier : `/` ou `Ctrl F` (barre), `Entrée` (chercher), `Ctrl Entrée` (ouvrir la fiche de la suggestion), `Alt ←` /
  `Alt →` (historique de l’écran, 40 étapes, sans relecture), `F5` (actualiser la liste, lecture annoncée), `Maj F10`
  (menu de la ligne), `Ctrl A` (tout sélectionner).
- Composants locaux (demandes au kit) : anneau animé de la barre et liste de suggestions, sélecteur de verdict,
  éventail de sélection multiple, rampe de lancement, tableau de comparaison, tableau de diagnostic, catalogue.
