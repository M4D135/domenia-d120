# Atelier de requêtes — contrat des opérations (`requetes.*`)

Écran `requetes` de Domenia 2 (lot Domenia 1 `requetes`, fonctions REQ-001 à REQ-069). Ce document complète
[`OPERATIONS.md`](../OPERATIONS.md) (enveloppe, règles JSON, classes d’opération, codes communs) : toute opération absente
d’ici est refusée par le pont (`operation.unknown`).

- Modules : `Domenia.Bridge/Operations/RequetesOperations.cs` (atelier, bibliothèque, partage) et
  `RequetesWmiOperations.cs` (WMI avancé), écran `requetes`, trouvés par réflexion (aucune liste centrale).
- Règles pures : `Domenia.Core/Screens/Requetes/` (espace de noms `Domenia.Core.Queries`) : modèles, catalogue,
  moteur à trois valeurs, LDAP (RFC 4515, schéma, évaluateur), traduction recette ↔ LDAP, analyses, bibliothèque,
  modèles livrés, WQL.
- Lecteurs : `IQueryWorkshopReader` (données locales et relevés) et `IQueryWmiReader` (WMI d’un poste). En simulation :
  `Domenia.Simulation/Screens/Requetes/` (`SimulatedQueryWorkshopReader`, `SimulatedQueryWmiReader`, catalogue fictif
  `SimulatedWmiCatalog` partagé par le WMI avancé et la collecte).
- Bibliothèque : `QueryLibrary` (Core, règles) sur un support `IQueryLibraryStore` : `QueryLibraryFiles` (Bridge, fichier
  propre à l’atelier) ou `MemoryQueryLibraryStore` (capture, E2E, tests) ; service partagé `RequetesServices.Library(context)`,
  que l’Accueil et la Fiche réutiliseront pour les widgets.
- Page : `web/js/pages/requetes.js` et `web/js/pages/requetes/*.js`, styles `web/css/pages/requetes.css`.

## 1. Principes

1. **Lecture seule par défaut.** L’atelier n’écrit jamais dans l’annuaire. Ses seules écritures sont locales
   (`LocalWrite`) : bibliothèque (son propre fichier, § 3.5), brouillon et périmètre propre (préférences), fichiers
   d’export (dossier `Exports`).
2. **Aucune lecture réseau sans geste explicite.** L’aperçu, la couverture, le plan de collecte, la répartition, le
   détail et l’explication sont calculés sur les données locales (base AD locale ou annuaire fictif). Les seules
   lectures distantes sont la collecte (`requetes.collect.run`, `requetes.collect.object`) et le WMI avancé
   (`requetes.wmi.namespaces`, `.classes`, `.schema`, `.run`, `.relation`), chacune après un geste et une confirmation : à
   chaque collecte, SELECT et relation ; une fois par poste et par session pour les métadonnées WMI (espaces, classes,
   schéma). Elles sont servies par l’annuaire fictif en simulation (`ServedInSimulation`).
3. **Jamais tout le domaine sans garde.** La collecte refuse un périmètre égal au domaine (`ScopeRules.EnsureNotDomainRoot`)
   et lit exactement le plan figé (ticket à usage unique, 10 minutes) : un plan ne se rejoue pas.
4. **Trois valeurs.** Chaque objet est *Correspond*, *Ne correspond pas* ou *Inconnu* (RFC 4511 « Undefined »). Une
   mesure absente, expirée, partielle ou illisible ne décide jamais : elle rend le verdict inconnu, jamais faux. Les
   inconnus sont comptés à part, exclus des sélections pour Recherche et visibles dans les exports.
5. **Aperçu figé.** Un aperçu garde sa définition (empreinte), sa population, ses verdicts et la version des données :
   pages, répartition, détail, explication, export et sélection portent sur ce calcul, jamais sur le brouillon modifié
   depuis. `stale: true` signale des données changées depuis ; six aperçus récents sont gardés en mémoire.
6. **Aucun secret** n’est lu, journalisé ni passé en ligne de commande : les propriétés WMI de secret sont écartées
   (`WqlRules.IsSecret`), aucune valeur LAPS n’est lue (seule la présence des attributs d’expiration est interrogeable).

## 2. Recette (`QueryRecipe`)

Format Domenia 1 `Domenia.Query/1` et `/2` (PascalCase) lu tel quel ; Domenia 2 écrit `Domenia.Query/3` (cible
`user`/`group`, conditions LDAP) seulement quand la recette en a besoin (`MinimalFormat`). Le lecteur est strict :
propriété inconnue, format plus récent ou valeur invalide → `query.invalid`, avec la raison en français. L’écrivain est
compatible Domenia 1 (PascalCase, valeurs nulles omises, `Target` omis pour les postes).

| Champ | Sens |
|---|---|
| `format`, `id` (`^[a-zA-Z0-9_.-]{1,80}$`), `name` (120) | identité ; un modèle livré a l’identifiant `template.<…>` |
| `target` | `computer` (défaut), `user`, `group` |
| `junction`, `clauses` | critères simples (64 au plus) en ET (`all`) ou OU (`any`) |
| `expression` | arbre ET / OU / NON et collections d’instances de sonde (8 niveaux, 256 nœuds) |
| `groupBy` | information de répartition (exacte, 100 000 catégories au plus) |
| `refinements`, `probeSelection`, `objectIds` | segment (ET) : valeur de répartition, segment de sonde, sélection figée (20 000 GUID) |
| `parameters`, `parameterValues` | paramètres réutilisables (32) et valeurs choisies ; l’empreinte suit la valeur effective |
| `coherenceHours` | écart maximal entre les dates sources d’un objet (au-delà ou sans date : inconnu) |
| `readDefinition` | SELECT WMI testé et mémorisé (`Domenia.WmiRead/1`), source des informations `detail:<clé>:exists|count` |

Valeur d’une condition : `null`, texte, nombre, booléen ou `{ "parameter": "Nom" }`. Les nombres saisis avec une unité
sont convertis (`8192 Mo` → 8 Go, `48 h` → 2 j) : `requetes.value.preview` montre la conversion en direct.

Identifiants d’informations : champ du catalogue (`os`, `diskFreePercent`…), sonde `probe:<id>`, propriété d’instance
`instance:<sonde>:<propriété>`, résultat mémorisé `detail:<clé>:exists|count`, attribut brut `ldap:<attribut>` et filtre
brut `ldap.filter` (valeur : filtre RFC 4515).

## 3. Opérations

Classes : **L** `Local`, **LR** `LocalRead`, **LW** `LocalWrite`, **NR** `NetworkRead` (servie en simulation).

### 3.1 Catalogue et validation

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `requetes.catalog` | L | `target?` | `target`, `targets`, `fields` (`QueryField` : id, nom, type, source, unité, catégorie, description, exemple, collecte, disponibilité, coût, fraîcheur, détail technique, choix, horloge, attribut LDAP, opérateurs), `instanceFields`, `collections`, `ldapAttributes` (nom, syntaxe, lu, description, exemple), `ldapFields` (les mêmes attributs en informations `ldap:<attribut>` du constructeur visuel), `operators`, `categories`, `sources`, `limits` (dont `pack` 16 Mio et `packPart` 400 000 caractères) |
| `requetes.validate` | L | `recipe` | `valid`, `errors`, `warnings`, `recipe` (normalisée), `fingerprint` (SHA-256), `conditionCount`, `summary`, `outline`, `parameters`, `requested`, `clocks`, `ldap` (`filter`, `pretty`, `exact`, `preFilter`, `residual`, `notes`), `command`, `format` |
| `requetes.ldap.read` | L | `text` (8 192), `recipe` | `valid`, `error`, `position` (1-based), `recipe` (cible déduite de `objectCategory`/`objectClass`), `pretty`, `warnings`, `validation` |
| `requetes.value.preview` | L | `target`, `field`, `text` | `valid`, `value`, `text` (conversion lisible) |

Synchronisation texte ↔ critères : quand toute la recette s’exprime en LDAP (`exact`), le texte et les critères se
suivent dans les deux sens ; sinon le texte montre la partie annuaire, verrouillé (« Modifier le texte quand même »
remplace les conditions par le seul filtre, après avertissement).

`exact` veut dire : le filtre retient exactement les correspondants de l’aperçu, attribut absent compris. Règles qui le
garantissent (`QueryLdap.AbsentIsFalse`, `Part.Definite`) :

- une information qui est la copie d’un attribut texte conservé par Domenia (`name`, `operatingSystem`, `description`…)
  traite l’absence comme LDAP : la condition est fausse, sa négation vraie (un attribut vide est un fait, pas une mesure
  manquante) ; relevés, sondes et calculs gardent « inconnu » pour une valeur absente ;
- une négation (groupe NON, « est différent de ») sur une information qui reste inconnue quand elle est absente sort du
  filtre exact : elle est évaluée localement et listée dans `residual` (puce « LDAP + conditions locales ») ;
- un texte LDAP saisi n’est traduit en information du catalogue que si ce catalogue donne le même verdict qu’LDAP ; sinon
  il devient un attribut brut `ldap:<attribut>`, évalué par l’évaluateur LDAP (`(!(description=x))` reste vrai pour un
  objet sans description, comme sur le contrôleur et dans le script exporté).

Les attributs bruts sont des informations à part entière du constructeur visuel (catégorie « Attributs LDAP ») : ils
s’ajoutent, se modifient et se paramètrent comme les autres ; seul l’élément `ldap.filter` (filtre brut) se modifie dans le
texte. `company` n’est pas conservé par Domenia : sa condition reste indéfinie en local (aucune valeur inventée).

### 3.2 Périmètre

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `requetes.scope` | LR | — | `working` (OU de travail), `workshop` (OU propre ou `null`), `effective`, `wholeDomain`, `accountsInDomain`, `domain`, `base` (date, objets, complète, source, simulée), `counts` par cible |
| `requetes.scope.set` | LW | `dn` (ou `null` pour suivre l’OU de travail), `subtree` | `{ scope, persisted }` ; clé de préférence `requetes.scope.<sha256 de la racine>` |

Les postes suivent l’OU de travail ; les comptes et les groupes sont lus dans tout le domaine de la base locale (comme
sur l’Accueil), sauf OU propre à l’atelier.

### 3.3 Aperçu figé

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `requetes.preview` | LR | `recipe`, `limit?` (1 000, 5 000 au plus), `verdict?` (`auto` par défaut : correspondants, ou tous quand aucun ne correspond — Domenia 1 ouvre sur « Correspondants ») | `id`, `evaluatedAt`, `fingerprint`, `population` (domaine, OU, cible, nom, version des données, phrase), `counts` (`total`, `population`, `matched`, `unknown`, `noMatch`), `columns` (informations interrogées d’abord, dans l’ordre des conditions, puis colonnes de la cible), `rows` (du verdict retenu), `hasMore`, `verdict`, `pageTotal`, `groups` (10 valeurs, « Autres valeurs », « Valeur inconnue »), `ldap`, `warnings`, `summary` |
| `requetes.preview.page` | LR | `evaluationId`, `verdict` (`all`, `match`, `unknown`, `noMatch`), `text?` (mots du nom ou du DN, sans accents, sur toute la population figée), `state` (`all`, `active`, `disabled`), `offset`, `limit` | `rows`, `total`, `offset`, `limit`, `hasMore`, `stale` |
| `requetes.preview.groups` | LR | `evaluationId`, `text?`, `offset`, `limit` (100, 500 au plus) | répartition complète et exacte, paginée |
| `requetes.preview.object` | LR | `evaluationId`, `id` (GUID) | fiche locale (`fields` : valeur, état, date, demandée) et `explanation` (« Pourquoi ce résultat ? ») |
| `requetes.preview.segment` | L | `evaluationId`, `label`, `missing`, `value`, `excluded` | validation de la recette restreinte à la valeur (segment ET) |
| `requetes.preview.export` | L | `evaluationId`, `verdict`, `format` (`csv`, `json`) | export **préparé par le moteur** et gardé 30 minutes sous un jeton : `token`, `fileName`, `metadataFileName`, `rows`, `bytes`, `sha256`, `secretsMasked` (colonnes de secret masquées et comptées), `preview` (6 000 premiers caractères), `truncated`, `recomputed` (données changées depuis l’aperçu), `text`. CSV « ; », UTF-8, formules neutralisées, 200 000 lignes ; JSON : valeurs typées, états et dates des sources de chaque objet (relisible par le script PowerShell) |
| `requetes.export.content` | L | `token` | `content`, `metadata`, `fileName` : le contenu complet, pour le copier |
| `requetes.export.save` | LW | `token`, `metadata?` (vrai) | écrit **ce qui a été préparé** dans `%LOCALAPPDATA%\Domenia\Exports` (suffixe `-simulation`) : lignes recomptées et empreinte revérifiée, fichier et `.metadata.json` ensemble (fichiers temporaires, puis noms uniques ; une collision prend l’indice suivant ; sans ses métadonnées, le fichier est retiré), un jeton ne s’enregistre qu’une fois ; pour un pack, la version proposée avance alors (`nextVersion`). Refusé (`query.exportUnavailable`) quand les préférences ne sont pas persistantes (capture, E2E) |
| `requetes.search.apply` | L | `evaluationId` | fige les GUID des seuls correspondants (aperçu de moins de 10 minutes, données inchangées) ; la page ouvre ensuite Rechercher (`#/rechercher?requete=selection`), comme Domenia 1 |
| `requetes.search.selection` / `.clear` | L | — | sélection figée lue par l’écran Rechercher, ou retrait |

La page ne télécharge jamais de fichier elle-même (la navigation hors de `https://domenia.local/` est bloquée) et ne
renvoie jamais un contenu au moteur pour l’écrire : un export préparé se copie (`requetes.export.content`) ou s’enregistre
par son jeton (`requetes.export.save`). Aucune limite de taille de message ne s’applique donc aux exports et aux packs.

### 3.4 Couverture et collecte

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `requetes.coverage` | LR | `recipe`, `coherenceHours?` | disponibilité de chaque information (disponible, expirée, erreur, partielle, non lue), dates de chaque source, objets complets, incomplets, à périodes mêlées, fenêtre commune proposée (1, 6, 12, 24, 48, 72, 168, 336, 720, 2 160 ou 8 760 h ; 24 h au plus pour une mesure instantanée) |
| `requetes.collect.plan` | LR | `recipe`, `cacheMinutes` (15), `reuseDays` (0) | `ticket`, `expiresAt`, `plan` : postes à relire (désactivés exclus), familles (ping, inventaire, console, SELECT mémorisé), sondes, `detail` (le SELECT WMI enregistré avec la recette, relu sur les postes dont le résultat manque ou est trop ancien), informations manquantes, coût compté (`Faible`, `Modéré`, `Élevé` au-delà de 100 et de 500 postes, sondes lentes ou lectures WMI avancées : `workload.detailReads`) ; refusé pour une recette sans relevé (`query.collectRefused`) ou sur tout le domaine |
| `requetes.collect.run` | NR | `ticket` | relève exactement le plan, une fois (le SELECT mémorisé compris, jamais un WQL libre) ; événement `progress` ; compte rendu et journal ; un poste sans réponse garde ses anciennes valeurs |
| `requetes.collect.object` | NR | `evaluationId`, `id` | « Actualiser ce poste » : présence, inventaire, sondes et SELECT mémorisé de la requête pour ce seul poste |
| `requetes.object.test` | LR | `recipe`, `id` | verdict et explication du brouillon sur un seul objet, dans ou hors périmètre |
| `requetes.objects.find` | LR | `text`, `target` | 20 objets au plus de la base locale dont le nom contient le texte |

Règles de fraîcheur : cache de 15 minutes, inventaire de 5 minutes, mesures instantanées de 1 minute ; un ping ne
rajeunit jamais un inventaire ni une sonde (une horloge par source : `ad`, `presence`, `console`, `inventory`,
`probe:<id>`, `detail:<clé>`).

### 3.5 Bibliothèque, widgets, scripts

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `requetes.library.list` | LR | `search?`, `category?`, `source` (`all`, `templates`, `personal`, `archives`), `target?`, `sort` (`name` par catégorie puis nom, `recent` par date de révision), `offset`, `limit` (5 000) | lignes (modèles livrés, mes requêtes, archives), catégories, définitions illisibles conservées, `persistent` ; `source=personal&sort=recent&limit=100` donne le chargement rapide de Domenia 1 (« Ouvrir… », Ctrl O) |
| `requetes.library.get` | LR | `id` | détail d’usage : description, recette, empreinte, révisions, provenance déclarée, sources, collecte, widgets, widgets retirés par l’archivage (`archivedWidgets`), éléments liés (`consumers`), résumé |
| `requetes.library.impact` | LR | `id`, `recipe?` | revue d’impact : différences, widgets liés (révision liée), liens qui ne pourront plus s’afficher (`orphan` : widget du poste d’une recette qui ne porte plus sur les postes, ou requête absente), favoris de Recherche et sélection figée (`view`), règles de santé (`health`, gardent leur révision), compteurs `widgets`, `orphans`, `views`, `alerts`, `targetChanged` |
| `requetes.library.save` | LW | `recipe`, `category?`, `description?`, `expectedRevision`, `mode` (`update`, `copy`, `migrate`) | `id`, `revision`, `fingerprint`, `recipe`, `receipt` (persisté, relu sur le disque, révision, empreinte, date), `written`, `migratedWidgets`, `droppedWidgets`, `remote` ; un modèle se copie ; révision dépassée → `query.revisionChanged` ; `update` d’une définition modifiée qui a des widgets → `query.impactRequired` (la revue d’impact choisit `migrate` ou `copy`) |
| `requetes.library.archive` | LW | `id`, `expectedRevision` | nouvelle révision archivée ; ses widgets retirés dans la **même écriture** et gardés avec l’archive (`removedWidgets`) |
| `requetes.library.restore` | LW | `id`, `expectedRevision`, `restoreWidgets?` (vrai) | nouvelle révision active ; les widgets retirés par l’archivage reviennent, liés à cette révision (`restoredWidgets`), depuis le reçu comme depuis la bibliothèque |
| `requetes.library.revert` | LW | `id`, `revision`, `expectedRevision`, `mode?` (`update`, `migrate`) | une révision gardée devient une nouvelle révision ; les widgets ne la suivent qu’avec `migrate` |
| `requetes.widget.save` | LW | `recipe`, `board` (`fleet`, `computer`), `visual` (`kpi`, `text`, `bar`, `pie`, `column`), `title`, `expectedRevision`, `category?`, `mode?` (`update`, `copy`, `migrate`) | recette et lien de widget dans la **même écriture** ; mêmes règles d’impact que `library.save` (jamais de migration imposée) ; la page ouvre ensuite le plan de collecte du widget (confirmé avant toute lecture) |
| `requetes.widget.list` / `.remove` | LR / LW | — / `id` | widgets, révision évaluée, `displayable`, état (« confirmez la mise à jour » quand la requête a avancé) |
| `requetes.widget.evaluate` | LR | `id`, `computer?` (GUID, tableau d’un poste) | évaluation locale de la **révision liée** : `counts`, `groups` (10 valeurs), `text`, `needsConfirmation` ; pour la fiche d’un poste, `computer` (verdict et explication) ; l’atelier en tire l’aperçu vivant de ses widgets, l’Accueil et la Fiche s’en serviront pour les afficher |
| `requetes.consumer.bind` / `.release` | LW | `kind` (`search`, `health`), `id`, `recipeId`, `title`, `scope?` / `kind`, `id` | déclaration d’un élément d’un autre écran qui utilise une requête (favori de Recherche, règle de Santé), listé par la revue d’impact ; 249 au plus |
| `requetes.script` | L | `recipe`, `format` (`powershell`, `json`, `ldap`, `command`), `searchBase?` | export préparé (`token`, `content`, `fileName`) : script PowerShell 5.1 commenté (§ 3.9), recette JSON, filtre indenté ou commande |
| `requetes.cmdlets` | LR | `text?`, `module?`, `source?` (`auto`, `installed`, `builtin`) | cmdlets ActiveDirectory et LAPS : aide des modules installés sur ce poste (fichiers MAML lus localement, jamais PowerShell, jamais le réseau ; par défaut en mode annuaire, sur demande en simulation) ou référence intégrée ; synopsis, syntaxe, paramètres, exemple, aide complète, `-Credential`, écriture ou lecture (jamais exécutées) |
| `requetes.details.list` | LR | `requestKey?`, `offset`, `limit` (250) | résultats des SELECT WMI mémorisés par poste (nombre d’instances, date, lecture complète ou non, erreur), par pages de 250, et la liste des SELECT connus ; aucune lecture distante |
| `requetes.draft.get` / `.keep` | LR / LW | — / `recipe` (ou `null`), `base?` (`id`, `source`, `revision`, `fingerprint`) | brouillon repris à la réouverture avec la révision dont il part (`requetes.draft`, 64 Kio) : une bibliothèque passée à une autre révision depuis est signalée avant tout enregistrement |

Stockage de la bibliothèque : **un fichier par domaine**, à part des préférences (dont il ne menace jamais le document),
`%LOCALAPPDATA%\Domenia\Requetes\bibliotheque-<32 hex de la racine>.json` (`bibliotheque-simulation-…` en simulation),
format `domenia.queryLibrary` version 2 : recettes (révision, 5 révisions gardées, widgets retirés par l’archivage,
provenance), widgets, éléments liés, journal d’import (40 entrées), version proposée de chaque pack, enregistrements
illisibles conservés tels quels. 16 Mio et 5 000 requêtes au plus. Chaque écriture prend un verrou commun à tous les
processus Domenia de la machine, **relit le fichier**, vérifie la révision attendue sur ce qu’elle vient de lire (une autre
instance ne s’efface donc jamais), écrit un fichier temporaire vidé sur le disque puis le déplace sur le document, et
**relit le document sur le disque** avant de dire « relue ». Un disque qui refuse l’écriture ne change rien et le dit
(`query.storeFailed`) : le brouillon reste dans l’atelier. Un document illisible est mis de côté
(`.illisible-AAAAMMJJ-HHmmss`) avant d’être remplacé ; un document d’une version plus récente reste en lecture seule. En
capture, en E2E et dans les tests : mémoire seulement (`MemoryQueryLibraryStore`). La bibliothèque SQLite de Domenia 1
(`domenia_query_recipes`) passera par Domenia.Store (vague 3) ; d’ici là, un pack exporté par Domenia 1 s’importe (§ 3.6).

### 3.6 Partage (packs)

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `requetes.pack.version` | LR | `name` | version proposée pour le prochain export (elle avance quand le fichier est enregistré) |
| `requetes.pack.export` | LR | `name`, `version`, `ids`, `origin?` | pack **préparé** (`token`, `count`, `version`, `nextVersion`, extrait) : `Domenia.QueryPack/3`, identité, version, origine déclarée, recettes, `ContentSHA256` sur les empreintes ; 5 000 recettes et 16 Mio au plus ; rien n’est écrit avant `requetes.export.save` |
| `requetes.pack.part` | L | `upload?` (sauf pour la partie 0), `index`, `count` (64 au plus), `text` (400 000 caractères) | reçoit, dans l’ordre, un pack trop gros pour un seul message (16 Mio en tout, gardé 10 minutes) ; `upload` à repasser |
| `requetes.pack.examine` | LR | `content` (900 000 caractères) ou `upload` | examen sans écriture : format, provenance, version (et version déjà importée), intégrité (vérifiée, ou « non vérifiable » pour un pack Domenia 1), état de chaque recette (`new`, `identical`, `conflict`, `archived`, `foreignDomain`), différences, actions admises ; ticket d’examen à usage unique |
| `requetes.pack.apply` | LW | `examinationId`, `choices` (`ignore`, `create`, `copy`, `replace` par recette) | créées, remplacées, copiées, ignorées, reçu ; une seule écriture, révisions revérifiées ; point de restauration |
| `requetes.pack.history` / `.rollback` | LR / LW | — / `importId` | imports restaurables (journal de 40 entrées) ; restauration (définitions remplacées remises, créations retirées avec leurs widgets, une requête modifiée depuis est refusée et signalée ; une restauration interrompue se reprend) |

### 3.7 WMI avancé (un poste à la fois)

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `requetes.wmi.cache` | LR | `computer`, `namespace`, `className?`, `filter?` | métadonnées déjà lues (24 h) et dernier SELECT testé ; aucune lecture |
| `requetes.wmi.namespaces` | NR | `computer`, `namespace` | espaces enfants directs (500 au plus) ; la page demande confirmation une fois par poste et par session avant les lectures de métadonnées |
| `requetes.wmi.classes` | NR | `computer`, `namespace`, `filter?` (nom, `*` final) | définitions de classes (2 000 au plus) |
| `requetes.wmi.schema` | NR | `computer`, `namespace`, `className` | propriétés (type CIM, clé, unité, description), propriétés de secret écartées |
| `requetes.wmi.build` | L | `computer`, `namespace`, `className`, `properties` | `SELECT p1, p2 FROM Classe` depuis le schéma relu |
| `requetes.wmi.analyze` | L | `computer?`, `computerName?`, `namespace`, `query`, `limit` | rapport local : classe, propriétés et clés, propriétés absentes du schéma, préconditions, limites, prudence, état « testé » |
| `requetes.wmi.run` | NR | `computer`, `namespace`, `query`, `limit` (1 à 2 000) | instances lues, partiel ou non, date ; marque la requête testée sur ce poste |
| `requetes.wmi.relations` | L | `className` | relations déclarées (disque ↔ partition, partition ↔ volume, carte ↔ configuration, service ↔ dépendances ↔ processus) |
| `requetes.wmi.relation` | NR | `computer`, `namespace`, `preset`, `rowId` | instances liées à une instance du dernier résultat, par une relation déclarée seulement (aucune jointure libre) |
| `requetes.wmi.recipe` | L | `computer`, `namespace`, `query`, `limit`, `name?` | recette « WMI · Classe » sur les résultats mémorisés, seulement pour un SELECT testé sous cette forme sur ce poste (`query.wmiNotTested` sinon) |

Grammaire WQL fermée (Domenia 1 `ConvertFrom-DomeniaWqlSelect`) : propriétés explicites (64), une classe, `WHERE` avec
`=`, `<>`, `!=`, `<`, `>`, `<=`, `>=`, `LIKE`, `IS [NOT] NULL`, `AND`, `OR`, `NOT` ; 8 niveaux, 512 jetons, 8 192
caractères ; espaces de noms locaux `root\…` seulement ; `Win32_UserAccount` et `Win32_Group` bornés aux comptes locaux.

### 3.8 Retour à l’écran d’origine

Un écran qui ouvre l’atelier passe `retour=<écran>`, et peut passer `retourParams` (ses propres paramètres de route,
`a=1&b=2`, 2 048 caractères : son onglet par exemple) et `retourFocus` (identifiant du contrôle qui avait le focus).
« Revenir à l’écran … » rouvre cet écran avec ces paramètres puis rend le focus à ce contrôle dès qu’il est affiché
(2 s au plus).

### 3.9 Script PowerShell exporté

Script Windows PowerShell 5.1 autonome, commenté (conditions, sources, paramètres, limites), recette en littéral JSON ASCII,
jamais exécuté par l’export, sans identifiant ni connexion pour l’usage 1 :

1. `-RecordsPath export.json` (ou `-Records`) : évalue **toute** la requête sur un export JSON de l’aperçu (conditions en
   ET/OU, groupes ET/OU/NON, segment, sélection figée, paramètres avec `-ParameterValues @{ Nom = valeur }` et leurs bornes,
   fenêtre de cohérence sur les dates exportées), en logique à trois valeurs comme l’atelier (attribut AD vide : faux) ;
   `-Selection Match|Unknown|NoMatch|All` ; sortie : `Id`, `Nom`, `CheminAD`, `Verdict`, `Valeurs`, `Etats`. Les collections
   d’instances et les attributs LDAP bruts ne sont pas dans l’export : leurs conditions restent inconnues.
2. `-SearchBase` : lit en lecture seule les candidats de l’annuaire (`Get-AD* -LDAPFilter` avec le préfiltre).

`-ShowDefinition` affiche la recette.

## 4. Codes d’erreur propres

| Code | Cas |
|---|---|
| `query.invalid` | recette, argument ou valeur refusés (raison en français) |
| `query.ldapInvalid` | filtre LDAP illisible (position donnée par `requetes.ldap.read`) |
| `query.evaluationUnknown` | aperçu inconnu, expiré ou trop ancien pour l’action |
| `query.objectUnknown` | objet absent de l’aperçu ou de la base locale |
| `query.notFound`, `query.revisionChanged`, `query.templateReadOnly`, `query.libraryFull` | bibliothèque |
| `query.impactRequired` | définition modifiée d’une requête qui a des widgets, sans choix de la revue d’impact |
| `query.storeFailed` | fichier de la bibliothèque illisible ou non écrit pour l’instant (verrou, droits, disque) : rien n’a changé |
| `query.packInvalid`, `query.importUnknown`, `query.rollbackRefused` | partage |
| `query.collectRefused` | rien à collecter, périmètre égal au domaine, plan inconnu, expiré ou déjà lancé |
| `query.wmiInvalid`, `query.wmiUnknownComputer`, `query.wmiNotTested` | WMI avancé |
| `query.exportUnavailable`, `query.exportTooLarge` | exports |

## 5. Simulation

Les lecteurs simulés tirent leurs valeurs d’un sous-flux déterministe de la graine (`ScreenStream("requetes")`) : mêmes
postes, mêmes sondes, mêmes valeurs à chaque lancement. Les relevés viennent des observations du monde fictif
(`World.Observations`), sans consommer la séquence de délais de l’Accueil ; la collecte simulée met à jour un calque en
mémoire (dates et valeurs relevées). Le catalogue WMI fictif expose les espaces `root`, `root\cimv2`, `root\default`, `root\subscription`, `root\Interop`,
`root\cimv2\power`, `root\cimv2\mdm` et ceux des sondes, des classes tirées des 111 sondes et des classes usuelles
(disques, partitions, cartes, services, comptes locaux, associations), avec des instances plausibles et les remarques de
prudence de Domenia 1 (fournisseur MSI refusé, classe coûteuse à filtrer). Latences fictives : `requetes`, `requetes/measure`, `requetes/wmi`, `requetes/wmi/select`.

## 6. Mode annuaire (vague 3)

Ce qui changera quand `Domenia.Ad` branchera l’atelier sur un vrai domaine ; le contrat des opérations ne change pas.

### 6.1 Lectures LDAP

- **Base locale d’abord.** L’aperçu reste calculé sur la base locale (copie de l’annuaire lue par l’OU de travail) :
  aucune lecture LDAP pour un aperçu, une répartition, une explication ou une couverture.
- **Rafraîchir le périmètre** (geste existant de l’Accueil) relit l’OU avec le **préfiltre** de la recette
  (`ldap.preFilter`) : sur-ensemble de tout objet qui peut correspondre ou rester inconnu (bornes hautes et basses,
  inversion des NON), chaque objet lu étant ensuite réévalué localement. Le préfiltre ne retire jamais un objet inconnu.
- Requête : `SearchRequest` paginée (`PageResultRequestControl`, pages de 500), base = DN du périmètre, portée
  `Subtree` ou `OneLevel`, `SizeLimit` 20 000 objets, `TimeLimit` 120 s, contrôle de tri désactivé.
- Attributs demandés : ceux du schéma `LdapSchema` marqués « lus par Domenia » et ceux des informations demandées par la
  recette — postes : `objectGUID`, `cn`, `distinguishedName`, `dNSHostName`, `operatingSystem`,
  `operatingSystemVersion`, `userAccountControl`, `lastLogonTimestamp`, `pwdLastSet`, `whenCreated`, `whenChanged`,
  `description`, `managedBy`, `location`, `memberOf`, `msLAPS-PasswordExpirationTime`, `ms-Mcs-AdmPwdExpirationTime`
  (dates seulement, jamais de mot de passe) ; comptes : `sAMAccountName`, `userPrincipalName`, `displayName`, `mail`,
  `department`, `title`, `manager`, `lockoutTime`, `badPwdCount`, `accountExpires`, `adminCount`,
  `msDS-UserPasswordExpiryTimeComputed`, `msDS-User-Account-Control-Computed` ; groupes : `groupType`, `member` (plages),
  `memberOf`, `description`, `managedBy`. Un attribut non lu reste « indéfini » dans l’évaluation.
- Règles d’appariement : `1.2.840.113556.1.4.803` et `.804` évaluées par le contrôleur dans le préfiltre et localement ;
  `1.2.840.113556.1.4.1941` (chaîne) envoyée telle quelle, réévaluée localement sur la base (`DirectoryLdapChain`).
- `badPwdCount` et `lockoutTime` ne sont pas répliqués : relus sur le contrôleur de la session et datés comme tels.

### 6.2 Relevés des postes (collecte)

- Ping ICMP (1 essai, 1 000 ms), inventaire léger WMI/CIM (`Win32_OperatingSystem`, `Win32_ComputerSystem`,
  `Win32_LogicalDisk` C:, `Win32_BIOS`), console (`Win32_ComputerSystem.UserName`), sondes du catalogue
  (`QueryProbeCatalog`, 111 sondes, mode « Tout » pour les collections).
- Transport : CIM sur WinRM (`WSMan`), repli DCOM seulement si la politique le permet ; jamais d’activation de WinRM ni de
  règle de pare-feu par Domenia ; Kerberos du compte de la session, aucune autre identité.
- **Budgets** : 8 postes en parallèle, 30 s par poste (10 s pour le ping et la console), 120 s par sonde lente, 15 min
  pour un plan entier ; arrêt propre sur annulation ; un poste sans réponse garde ses anciennes valeurs datées.
- Coût annoncé avant confirmation (bandes de Domenia 1) : `Faible` (100 postes au plus, sondes rapides, aucune lecture WMI
  avancée), `Modéré` (plus de 100 postes, ou une sonde lente ou une relecture du SELECT mémorisé), `Élevé` (plus de
  500 postes, ou plus de 100 lectures lentes).
- Désactivés exclus, périmètre égal au domaine refusé, plan figé à usage unique : identique à la simulation.

### 6.3 WMI avancé

- `ManagementScope` / CIM sur le seul poste choisi, espace `root\…` local au poste, aucune méthode appelée.
- Budgets : 15 s pour les espaces de noms (500), 30 s pour les classes (2 000), 15 s pour un schéma (1 024 propriétés),
  60 s pour un SELECT (2 000 instances, `ReturnImmediately`, `Rewindable = false`), 30 s pour une relation.
- Métadonnées gardées 24 h en mémoire de session ; résultat du dernier SELECT par poste gardé pour les relations et la
  recette ; propriétés de secret écartées avant tout retour à la page ou au journal.

### 6.4 Écran Rechercher et Accueil

- Rechercher lit `requetes.search.selection` pour filtrer ses résultats par la sélection figée (GUID, date, empreinte), et
  déclare ses favoris de requêtes par `requetes.consumer.bind` (`kind: search`).
- L’Accueil et la Fiche affichent les widgets de requêtes (`requetes.widget.list`, puis `requetes.widget.evaluate` pour
  chacun, `computer` en plus sur la fiche d’un poste) ; une révision plus récente demande l’accord de l’opérateur
  (`needsConfirmation`). Santé déclare ses règles par `requetes.consumer.bind` (`kind: health`).
