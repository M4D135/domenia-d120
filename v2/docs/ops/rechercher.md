# Écran « Rechercher » — contrat des opérations

Module `SearchOperations` (`src/Domenia.Bridge/Operations/SearchOperations.cs`), écran `search`, route `#/rechercher`.
Règles pures : `src/Domenia.Core/Screens/Search/` (`SearchText`, `SearchMatcher`, `SearchLists`, `SearchViews`,
`SearchSurvey`, `SearchMemoryRules`, `SearchDetails`, `SearchRowFactory`) ; service `SearchService`, mémoire
`SearchMemory`. Lecteur : `ISearchReader`, implémenté en simulation par `SimulatedSearchReader`
(`src/Domenia.Simulation/Screens/`). Parité : `RCH-001` à `RCH-137` (`docs/features.json`). État :
`docs/status/rechercher.json`. Tests : `tests/Domenia.Tests/SearchRulesTests.cs`, `SearchOperationsTests.cs`,
`SearchTextVectorsTests.cs` (vecteurs partagés avec la page : `tests/vectors/search-text.json`), tests de la page
`tests/web/rechercher.test.mjs`, scénarios `tests/e2e/rechercher/*.json` (écrits, non exécutés : décision du 21/10).
Aperçu dans un navigateur : `web/js/mock-search.js`.

## 1. Règles communes

- **Classes.** Les lectures de listes (`search.run`, `search.browse`, `search.view`, `search.more`, `search.revalidate`,
  `search.reconcile`, `search.preload`, `search.containers`) sont `LocalRead` en simulation et `NetworkRead` en mode
  annuaire. Les lectures de la base locale (`search.suggest`, `search.preview`, `search.compare`, `search.localQuery`,
  `search.catalog`, `search.measures`, `search.survey.plan`) sont `LocalRead` partout ; `search.memory` est `LocalWrite`
  (reprise unique des recherches de Domenia 1 dans les préférences). Les sondes sur
  geste (`search.survey.run`, `search.recheck`, `search.netdiag`, `search.dns.reverse`) sont `NetworkRead` dans les deux
  modes, servies par l’annuaire fictif (`ServedInSimulation`). La mémoire de l’écran (`search.recent.*`,
  `search.favorite.*`, `search.workspace.*`, `search.query.favorite`) est `LocalWrite` (préférences locales).
  `search.survey.stop`, `search.survey.state`, `search.survey.forget` et `search.checks.resume` sont `Local`. **Aucune écriture
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
- **Listes.** Chaque liste reçoit un `listId` ; le moteur garde les 24 dernières (périmètre, plan, type, vue, texte,
  dernière clé, identifiants déjà chargés dans leur ordre). `search.more` lit **seulement** les lignes suivantes (liste
  doublée, 20 000 au plus) et écarte toute ligne déjà chargée ; une liste en cours de lecture (suite, revérification)
  refuse une seconde lecture (`search.listBusy`), quel que soit son genre (recherche, OU, vue, adresse, requête locale).
- **Le moteur juge sur la liste, jamais sur la page.** Un relevé, un diagnostic ou une revérification au clic portent sur
  des lignes **de la liste** (`listId`) : chaque GUID est vérifié parmi les lignes données par le moteur, et le contexte
  (recherche globale, terme, racine, vue sur tout le domaine, filtre) est déduit de la liste elle-même. La page n’envoie
  plus aucun « contexte ».
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
| `search.surveyPlanUnknown` | Plan de relevé inconnu, déjà utilisé ou expiré : rien n’est lu. Relancez la confirmation. | `search.survey.run` sans plan valide (un plan sert une fois, dix minutes). |
| `search.surveyTypedCount` | Nombre saisi différent du nombre de postes (n) : rien n’est lu. Confirmez de nouveau. | Au-delà de 100 postes, nombre saisi revérifié par le moteur. |
| `search.checksSuspended` | Vérifications sur sélection suspendues : le poste X a rejeté le compte distant… | Vérification au clic après un compte distant refusé (RCH-082), jusqu’à `search.checks.resume`. |
| `search.notWorkstation` | Cette ligne n’est pas un poste actif : aucune sonde n’est envoyée. | `search.recheck` sur un compte, un groupe, une OU, un poste désactivé. |
| `search.favoriteRefused` | (racine, OU hors du domaine ou inconnue localement, 50 favoris, favori absent) | Favori d’OU refusé. |
| `search.workspaceRefused` | (100 vues, nom déjà pris, bibliothèque trop volumineuse, OU hors du domaine) | Vue personnelle refusée. |
| `search.queryUnknown` / `search.queryRefused` | Requête inconnue / 200 favoris de requête au maximum. | Favori de requête. |

Plus les codes communs d’`OPERATIONS.md` § 1.4 (`arguments.invalid`, `ou.unknown`, `source.unavailable`,
`operation.cancelled`).

## 2. Opérations

| Opération | Classe (simulation / annuaire) | Arguments | Résultat |
|---|---|---|---|
| `search.run` | LocalRead / NetworkRead | `text`, `scope?` (DN de l’OU ou du conteneur de la racine choisi, `CN=Users`, `CN=Computers`, sous-OU incluses ; absent = domaine entier), `type?` (`all`, `users`, `computers`, `groups`, `ous`), `limit?`, `match?` (`prefix`, `contains`) | `SearchResult` (§ 3). Une adresse IPv4 ou MAC donne `kind = address` (base locale seulement) ; une IPv4 inconnue ajoute `dns` (offre, rien n’est résolu). |
| `search.browse` | LocalRead / NetworkRead | `dn` (OU, conteneur de la racine ou racine), `subtree`, `type?`, `limit?` | `SearchResult` `kind = browse` : contenu de l’OU, sans filtre caché (un terme filtre seulement les lignes chargées, côté page). |
| `search.containers` | LocalRead / NetworkRead | `counts?` (`false` par défaut) | Conteneurs de la racine (`Users`, `Computers`, conteneurs système repliés à part) ; leur nombre d’objets seulement avec `counts: true` (sinon `objects = -1` : en mode annuaire, compter coûte une requête par conteneur). |
| `search.view` | LocalRead / NetworkRead | `id`, `dn?`, `subtree`, `wholeDomain`, `limit?` | `SearchResult` `kind = view` : vue prête sur l’OU `dn` ou, explicitement (`wholeDomain: true`), sur tout le domaine (jamais relevable). Sans `dn` (ou avec la racine) et sans `wholeDomain` : `arguments.invalid`, jamais un repli silencieux sur tout le domaine. |
| `search.localQuery` | LocalRead | `id` (`local.*`), `dn`, `subtree`, `verdict?` (`match`, `unknown`, `noMatch`, `all`), `limit?` | `SearchResult` `kind = localQuery` avec `verdicts` (trois totaux, choix affiché) et `verdict` sur chaque ligne. |
| `search.selection` | LocalRead | `ids` (GUID, 1 à 20 000), `label` (nom de la requête), `at?` (date du gel) | `SearchResult` `kind = selection` : la sélection figée de l’atelier de requêtes (`requetes.search.selection`, lue par la page pour `#/rechercher?requete=selection`, REQ-048), lue dans les données locales seulement, dans l’ordre du gel, objets absents comptés ; liste complète d’emblée |
| `search.more` | LocalRead / NetworkRead | `listId`, `limit` | `SearchResult` `appended = true` : lignes nouvelles seulement ; `loaded`, `limit`, `continuation` cumulés. |
| `search.suggest` | LocalRead | `text`, `type?` | 8 suggestions au plus (objets de la base locale) ; les recherches récentes sont ajoutées par la page. |
| `search.preview` | LocalRead | `id` | `SearchPreview` : ligne, sections (identité, 80 attributs au plus avec leur date, présence, utilisateur connecté, matériel, adresses, association), source, troncature. |
| `search.compare` | LocalRead | `ids` (2 à 8) | `SearchComparison` : lignes avec valeur et date par objet, nombres de différences, d’égalités et d’inconnus, résumé. |
| `search.catalog` | LocalRead | — | 13 vues prêtes (`ad:<id>`) et 9 requêtes locales (`local:<id>`) avec coût, filtre LDAP, favoris. |
| `search.dns.reverse` | NetworkRead (servie) | `ip` (IPv4) | `{ ip, name, message }` : résolution inverse, 15 s au plus, sur le clic de l’offre. |
| `search.revalidate` | LocalRead / NetworkRead | `ids` (1 à 500) | `{ rows, missing, checkedAt, summary }` : lignes relues (après une écriture, une ligne) ; une absence n’est jamais présentée comme une suppression. |
| `search.reconcile` | LocalRead / NetworkRead | `listId` | `SearchReconcile` `{ listId, rows, added, moved, missing, loaded, checkpoint, readAt, summary }` : la dernière liste explicite relue avec son filtre, sa portée et sa taille (RCH-047) ; nouveaux objets ajoutés à la liste, objets sortis du périmètre suivis par leur GUID, absents « à revérifier » (jamais retirés), point de reprise tenu (RCH-048). |
| `search.measures` | LocalRead | `listId`, `offset?` | `{ rows, offset, next, total, readAt }` : mesures enregistrées des lignes de la liste, par pages de 250 (RCH-083). |
| `search.preload` | LocalRead / NetworkRead | `id` | `{ row, sourceLabel, readAt }` : fiche de la seule ligne cliquée relue (RCH-129) ; la page recopie ses valeurs dans la ligne (RCH-077). |
| `search.survey.plan` | LocalRead | `mode`, `listId`, `ids`, `scope?` (`results`, `selection`), `resume?` | `SurveyPlan` (§ 4) : `planId`, admission jugée sur la liste, titre, trois lignes, détails (profil, CIM, budgets, fenêtre de collecte, plan de reprise remplacé), `outsideWindow`, cibles exactes, lignes écartées, saisie du nombre au-delà de 100 postes, `expiresAt`. Rien n’est lu. |
| `search.survey.run` | NetworkRead (servie) | `planId`, `typedCount?` | `SurveyResult` (avec `status` et `resume`) ; évènements `search.survey.run:progress` après chaque lot (`SurveyProgress` : compteurs, lignes du lot, `status`). Un plan ne sert qu’une fois. |
| `search.survey.stop` | Local | `runId` | `{ stopped, message }` : les mesures reçues sont conservées, le reste devient le plan de reprise, rien n’est rejoué. |
| `search.survey.state` | Local | — | `{ resume, checksSuspended, suspendedReason }` : plan de reprise de la session et suspension des vérifications au clic. |
| `search.survey.forget` | Local | — | Même forme : plan de reprise abandonné (les mesures validées restent). |
| `search.checks.resume` | Local | — | Même forme : vérifications sur sélection reprises. |
| `search.recheck` | NetworkRead (servie) | `id`, `mode?` (`console` par défaut, `ping`), `listId` (obligatoire : le moteur juge sur la liste affichée), `onClick?` | `SearchRow` relue : un ping (et l’utilisateur connecté) du seul poste de la liste ; refusé sur une liste listée sur tout le domaine, pour une ligne absente de la liste, ou au clic pendant une suspension. |
| `search.netdiag` | NetworkRead (servie) | `listId`, `ids` (1 à 500, 50 postes actifs diagnostiqués au plus) | `NetworkDiagnostic` : lignes de la liste seulement, jamais sur une liste listée sur tout le domaine ; ping puis ports 445, 135, 5985, 5986 par poste, lignes écartées, résumé, rapport tabulé. |
| `search.policy` | LocalRead | — | `SearchPolicy` : réglages de l’administrateur lus dans `Domenia.config.json` à côté de l’exécutable (`Streaming.RevalidateListedObjects`, désactivée par défaut, et `Streaming.RevalidateIntervalSeconds`, 60 s, de 30 à 600 : revalidation des objets listés, RCH-073 ; `UI.Elements` « rechercher.<commande> » : `Hidden` ou `Disabled`, la GuiElementPolicy de Domenia 1, RCH-067) et budgets des relevés de Paramètres (préférence `settings.collection` : `concurrency` 1 à 8, `maxTargets`, ex `Collection.Concurrency` et `Park.MaxTargets`, RCH-090, RCH-093) ; échos par lots de 192 (RCH-092). Une valeur hors limites est ignorée et dite (`problems`). Rien n’est écrit. |
| `search.memory` | LocalWrite | — | `SearchMemoryState` (§ 5) ; au premier affichage d’un domaine, reprise unique des recherches enregistrées de Domenia 1 (RCH-004, `imported`) : `LocalWrite`, car cette reprise écrit une fois les favoris et le drapeau `search.legacyImported.*` dans les préférences locales. |
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
| `scope` | `{ mode (global, ou), dn, label, path, subtree, wholeDomain, chip }` : portée lisible (« Domaine entier », « Dans cette OU : Paris (dans Postes) · Sous-OU incluses » : le parent distingue les homonymes, RCH-013). |
| `type`, `text`, `match` | Critères de la lecture. |
| `plan` | `{ kind, valid, reason, hint, notes, tokens, identifier, address, ldapFilter, costly, freeText }` : ce qui a été cherché, le filtre LDAP du mode annuaire, le coût (joker en tête, « contient »). |
| `rows` | Lignes (`SearchRow`) : `id`, `kind`, `kindLabel`, `name`, `display`, `login`, `upn`, `mail`, `description`, `dn`, `container`, `state` (`key`, `label`, `tone`), `flags` (désactivé, verrouillé, à vérifier, mot de passe expiré, à changer, sans expiration, inactif, jamais connecté, expirant, expiré, administration…), `os`, `osVersion`, `lastLogon`, `changed`, `created`, `readAt`, `presence`, `console`, `association`, `address`, `group`, `verdict`, `rank`. |
| `loaded`, `limit`, `complete`, `limitReached` | État de la lecture. |
| `continuation` | `{ allowed, nextLimit, page, jumpLimit, jumpText, reason }` : « Charger la suite » (+ `page` lignes), puis « jusqu’à 1 000 / 5 000 / 20 000 ». |
| `counter`, `absence` | Compteur (« 100 lignes chargées · liste limitée à 100 : affinez ou chargez la suite ») et ce que la liste ne prouve pas. |
| `offer` | Offre « Chercher aussi les noms qui contiennent … » après 5 résultats ou moins d’un texte simple (rien n’est lu avant le clic). |
| `dns` | Offre de résolution inverse d’une IPv4 sans relevé local. |
| `view` | `{ id, name, note, wholeDomain, surveyAllowed, reason }` d’une vue ou d’une requête locale. |
| `verdicts` | `{ match, unknown, noMatch, shown, completeAt, coverage }` d’une requête locale : `completeAt` date depuis laquelle tous les postes du périmètre ont un relevé (dernière lecture complète couvrante, RCH-120), `coverage` la phrase qui le dit ou dit pourquoi elle manque. « Tous » liste les correspondants, puis les inconnus, puis les autres. |
| `sourceLabel`, `readAt`, `appended` | Source (« Annuaire fictif », « Annuaire en direct », « Relevés locaux »), date UTC, page ajoutée. |

Passes d’une recherche (Domenia 1 RCH-024) : identité exacte d’abord (compte, UPN, courriel, nom, nom DNS : jamais
poussée hors de la liste par des préfixes), puis préfixe des mots dans l’ordre des noms (reprise par clé), puis ANR
(début d’un mot dans le nom ou le nom affiché) tant qu’il reste de la place. Classement (Domenia 1,
`Get-DomeniaSearchRank`) : 0 compte, UPN ou courriel exact ; 1 nom exact ; 2 compte, UPN ou courriel qui commence ;
3 mot exact du nom ; 4 nom qui commence ; 5 mot qui commence ; 6 contenu ; 7 autre ; puis nom replié (accents, casse).
Une recherche simple (un mot, sans espace, joker ni parenthèse) publie d’abord les lignes de la base locale
(évènement `search.run:cached` : `{ text, rows, sourceLabel, readAt }`, RCH-055) ; les lignes fraîches les remplacent
(RCH-058).

## 4. Relevés de la liste et diagnostic

Modes : `ping` (« Qui répond ? »), `console` (« Qui est connecté ? »), `analyse` (matériel et requêtes des widgets),
`complete` (relevé léger plus correctifs, démarrage, services, TPM, BIOS, numéro de série ; jamais `Win32_Product` ni la
liste des processus), `unaddressed` (postes sans adresse connue).

Le moteur **planifie** sur la liste (`search.survey.plan`) puis **lance un plan** (`search.survey.run`) :

- chaque GUID doit être une ligne donnée par la liste `listId`, sinon `search.surveyRefused` (aucun GUID arbitraire) ;
- le contexte est déduit de la liste : recherche globale ou non, terme, racine, vue ou requête locale sur tout le
  domaine ; une liste listée sur tout le domaine (`view.surveyAllowed = false`) n’est **jamais** relevée, même une
  sélection partielle (code `wholeDomainView`, RCH-117) ; la liste entière de la racine sans filtre est refusée
  (`domainRoot`), une partie filtrée ou sélectionnée est son propre filtre (plafond seulement, RCH-090) ;
- admission (`SearchSurvey.Admit`) : liste vide, plafond (500 postes par défaut, 5 000 au plus), recherche globale sans
  terme ; les lignes qui ne sont pas des postes actifs sont écartées avec leur motif ;
- confirmation : trois lignes, puis les détails (RCH-091) — profil de collecte (`collection.profile` : `Standard`,
  `SlowNetwork`, `Troubleshooting` ; Standard par défaut) et ce qu’il réutilise (inventaire léger, sondes stables ;
  l’utilisateur console est toujours relu), regroupement CIM par poste, budgets (lots de 32 échos, 4 postes à la fois,
  15 s par poste, une seule tentative), fenêtre de collecte (hors fenêtre, le relevé part seulement sur confirmation),
  plan de reprise remplacé ;
- le plan (`planId`) vaut **dix minutes et une seule fois** ; au-delà de 100 postes, le nombre saisi est revérifié par
  le moteur (`search.surveyTypedCount`) ;
- pendant le relevé, l’état détaillé (`status`, RCH-099) : résultats validés et attente réelle, sources ralenties (plus de
  2 s) ou suspendues (compte distant refusé), nouveaux essais (aucun), capacités mémorisées (CIM joignable), requêtes CIM
  évitées (inventaire réutilisé), plan de reprise ;
- arrêt sur demande : les mesures reçues restent, les postes restants deviennent le **plan de reprise** de la session
  (`resume`), repris par `search.survey.plan` avec `resume: true` (nouvelle confirmation) ou abandonné
  (`search.survey.forget`) ; un nouveau relevé le remplace. Rien n’est jamais rejoué.

La page filtre ensuite la liste par issue (en ligne, sans réponse, erreur ; un second clic retire le filtre, RCH-095)
sans nouvelle lecture. Un compte distant refusé par un poste suspend les vérifications au clic (RCH-082) jusqu’à
`search.checks.resume`.

## 5. Mémoire de l’écran

Préférences locales, par domaine (clé `search.<nature>.<empreinte du DN racine>`), jamais de ligne ni de secret :
8 recherches et 8 objets récents (texte aplati à 80 caractères, doublons sans casse retirés), 50 favoris d’OU (libellés
distingués par l’OU parente en cas d’homonymie), 100 vues personnelles (OU, profondeur, type, présence, filtre local,
limite, jeu de colonnes, disposition de la grille) avec annulation du dernier retrait, 200 favoris de requête. Un
échec d’écriture disque est journalisé et rendu dans `warning` ; l’état reste en mémoire.
`SearchMemoryState` : `recents`, `favorites`, `workspaces`, `queryFavorites`, `undo`, `maxFavorites`, `maxWorkspaces`,
`persistent`, `warning`, `imported`. Au premier affichage d’un domaine, les recherches enregistrées de Domenia 1
(`ISearchReader.LegacySavedSearchesAsync` : fichier de réglages de Domenia 1 avec la base locale en mode annuaire,
échantillon fixe en simulation) deviennent des favoris d’OU **une seule fois** (`search.legacyImported.<empreinte>`) ;
une recherche texte sur tout le domaine n’a pas d’OU à épingler ; la liste d’origine n’est jamais modifiée (RCH-004).

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

Lectures raccordées par `Domenia.Ad/AdSearchReader` le 23 octobre 2026 (compilées, recette fonctionnelle encore à effectuer), toujours hors du fil de
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
| `search.revalidate`, `search.preload` | `(|(objectGUID=…)…)` par paquets de 40 GUID. | 500 objets |
| `search.reconcile` | La requête de la liste (même filtre, même base, même profondeur), taille = lignes chargées ; point de reprise (contrôleur, `invocationId`, USN) tenu avec la base locale. | taille de la liste |
| `search.containers` | Racine, `OneLevel`, `(objectClass=container)` ; nombre d’objets par conteneur en `OneLevel` seulement avec `counts: true` (`SizeLimit` 10 000). | 1 (+ n sur demande) requêtes |
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
de la liste affichée (180 s par défaut, 120 à 900 s, la première après un intervalle) est désactivée par défaut et ne
relit que l’annuaire (`search.reconcile`), jamais les postes. « Vérifier au clic » (désactivé par défaut, mémorisé) envoie
un ping (et lit l’utilisateur connecté si la sous-option est cochée) au seul poste cliqué, 180 ms après le dernier clic.
Aucun relevé ne porte sur tout le domaine.

## 8. Écran

- `web/js/pages/rechercher.js` et `web/js/pages/rechercher/*.js` (`bar`, `side`, `results`, `preview`, `actions`,
  `library`, `history`, `text`) ; styles `web/css/pages/rechercher.css` (règles sous `[data-page="rechercher"]`, y
  compris dans les tiroirs et dialogues, marqués `data-page="rechercher"`).
- Paramètres de route : `q` ou `ip` (texte cherché), `portee` (DN de l’OU qui borne la recherche), `type`, `match`
  (`contient`), `limite`, `ou` (DN affiché ou périmètre d’une vue), `sousou` (`0` : enfants directs), `vue` (vue prête),
  `domaine` (`1` : vue ou requête sur tout le domaine), `requete` (requête locale), `verdict`, `sel` (`first`, `pc`,
  `user`, `locked` ou un GUID), `ouvrir` (`requetes`, `vues`, `syntaxe`, `comparer`, `releve`, `menu`, `diag`,
  `historique`, `outils`, `suggestions`, `arbre`, `exporter`, `deverrouiller`), `largeur` (captures : l’écran se dispose
  comme dans une fenêtre de cette largeur, ses points de rupture étant des requêtes de conteneur).
- Disposition : la grande barre devient une barre fine après la première liste (l’analyse passe en puces dans le champ,
  le plan appliqué et son filtre LDAP s’affichent sous le champ pendant la saisie) ; l’arbre se replie en rail (de
  lui-même sur un écran étroit tant que l’opérateur n’a rien choisi) ; l’aperçu est un rail tant que rien n’est
  sélectionné, et s’ouvre par-dessus la liste sur un écran étroit ; la carte des résultats : historique des listes, titre,
  périmètre et fraîcheur, barre de commandes (action principale « Vérifier la liste », puis Actualiser, Exporter,
  Comparer, Revérifier, « Plus »), ligne de la grille (filtre rapide, « Filtres et options », jeux de colonnes), panneau
  « Filtres et options » replié à chaque ouverture (RCH-071), notices d’une ligne, état vide unique avec ses actions.
- Colonnes : une colonne dont aucune ligne n’a la donnée n’est pas proposée (type sur une liste d’un seul genre, compte,
  colonnes de poste, d’association, de groupe : RCH-061) ; le menu de ligne appartient à la page (aucune entrée du kit en
  double).
- Clavier : `/` ou `Ctrl F` (barre), `Entrée` (chercher), `Ctrl Entrée` (ouvrir la fiche de la suggestion), `Alt ←` /
  `Alt →` (historique de l’écran, 40 étapes, sans relecture), `F5` (actualiser la liste, lecture annoncée), `Maj F10`
  (menu de la ligne), `Ctrl A` (tout sélectionner).
- Composants locaux (demandes au kit) : anneau animé de la barre et liste de suggestions, sélecteur de verdict,
  éventail de sélection multiple, rampe de lancement, tableau de comparaison, tableau de diagnostic, catalogue, rails
  des panneaux, état vide à actions. Demandes au kit : option de la grille pour remplacer ses entrées de menu de ligne
  (aujourd’hui la page intercepte le menu), colonnes exclues du sélecteur, colonnes extensibles ; état déplié de l’arbre
  et rappel à l’ouverture ou à la fermeture d’une branche (RCH-045) ; opération hôte d’enregistrement de fichier (export
  CSV en fichier, RCH-069) ; évènement moteur `session.changed` (RCH-136 : la page relit la session au retour du focus).

### Raccordement du 23 octobre 2026

Les pages LDAP utilisent une reprise opaque `phase:nom AD brut` ; les noms identiques déjà affichés sont écartés par GUID, sans repli des accents dans la clé envoyée au contrôleur. La borne inclut les identités déjà affichées pour permettre une sentinelle même parmi des homonymes. Les trois passes partagent un budget total de 30 s (60 s pour « contient »), préparation locale incluse. La réponse du contrôle de tri est vérifiée. Un budget dépassé ne publie pas de liste présentée complète.

Le stockage des lectures ciblées ne remplace pas le dernier repère de census de l’OU. Chaque objet garde sa date d’observation ; le cache peut réunir des objets de lectures différentes et reste explicitement partiel. Une relecture GUID retourne seulement les objets réellement retrouvés, même si une ancienne projection est conservée pour consultation.

Les relevés de recherche passent par des périmètres CIM de 15 ou 30 s et vérifient le nom retourné par le poste avant de mémoriser l’inventaire. Ils conservent le ping terminé avant de commencer CIM. Le disque système est celui de `Win32_OperatingSystem.SystemDrive`, les adresses sont les IPv4 observées et datées. Le mode complet n’interroge ni les processus ni MSI. La sauvegarde locale des résultats est relue avant publication. La prise en charge du compte secondaire et du transport WSMan reste à raccorder au service partagé des comptes ; les requêtes présentes utilisent le contexte Windows de la session.

Validation actuelle : compilation Debug/Release sans avertissement, 11 tests nouveaux compilés ; tests et recette VM/AD à exécuter en fin de développement. Les repères `invocationId`/USN de réconciliation et l’import des anciennes observations D1 seront finalisés avec Synchronisation.
