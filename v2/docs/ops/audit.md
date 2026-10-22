# Domenia 2 — écran Audit AD : opérations du pont

Écran `audit` (`#/audit`), lot VM `audit`. Il porte l’**audit Active Directory** de Domenia 1 (Outils › Audit AD :
`Domenia-AdAudit.Model.ps1`, `.UI.ps1`, `.Worker.ps1`, `.xaml`) et la **vue du domaine** (onglet « Domaine » :
`Start-DomeniaDomainOverview`, `Start-DomeniaDomainLocalTotals`), soit les 23 fonctions AUD-001 à AUD-023, avec des
améliorations. Rédigé le 22 octobre 2026 ; tests écrits, non exécutés (décision de David du 21/10 : à la toute fin) ;
compilation Debug vérifiée dans la VM, 0 avertissement ; captures en simulation, thèmes sombre et clair.

Le contrat commun (enveloppe, règles JSON, classes, admission) est celui de [`OPERATIONS.md`](../OPERATIONS.md) § 1 ;
l’organisation du moteur est dans [`PLATFORM.md`](../PLATFORM.md). Les opérations sont dans le module
`Domenia.Bridge/Operations/AuditOperations.cs` ; le service et les règles pures dans `Domenia.Core/Screens/Audit/`
(`AuditService`, `AuditFindings`, `AuditPolicyRules`, `AuditGroupRules`, `AuditAclRules`, `AuditGpoRules`,
`AuditControllerRules`, `AuditIdentityRules`, `AuditTargets`, `AuditText`) ; l’interface de lecture `IAuditReader` et ses
lectures brutes (`AuditReads.cs`, la forme des workers de Domenia 1) ; la simulation dans
`Domenia.Simulation/Screens/Audit/` (`SimulatedAuditReader`, `SimulatedAuditAcl`, `SimulatedAuditData`).

**Lecture seule.** L’audit n’écrit rien, comme dans Domenia 1 (« Aucune écriture, aucun mot de passe lu ») : aucune
opération de plan ni d’écriture, aucun service démarré ni arrêté, aucun mot de passe, jeton, clé LAPS ou BitLocker lu ;
seules des dates circulent. Les correctifs se font dans les écrans qui écrivent (Comptes, Fiche), par le circuit de
[`WRITES.md`](../WRITES.md).

## 1. Fonctions couvertes

| Id | Fonction de Domenia 1 | Dans Domenia 2 |
|---|---|---|
| AUD-001 | Copier la vue pour un ticket | « Copier la vue » (texte tabulé, 2 000 lignes par section, cellules à 400 caractères) ; **amélioré** : export Markdown et CSV des constats, tout depuis la barre de l’écran |
| AUD-002 | Faits explicables | `AuditFact` : valeur, état (Constaté, Estimé, Refusé, Indisponible, Inconnu), source, limite ; liste animée avec pastille d’état |
| AUD-003 | Garde des lectures concurrentes | compteur par type de lecture (`createGuard` de la page) ; une nouvelle cible ou une sortie d’écran les annule toutes |
| AUD-004 | Lister les contrôleurs | `audit.dc.list` ; tuiles sélectionnables (10 au plus), rôles PDC et RODC |
| AUD-005 | Diagnostic des contrôleurs | `audit.dc.probe` ; verdict Sans écart, À vérifier, Non lu ; métriques sur la tuile |
| AUD-006 | Réplication par partenaire | `audit.dc.probe` (`neighbors`), onglet Réplication ; XML lu sans DTD (`AuditControllerRules.ParseNeighbor`) |
| AUD-007 | Services des contrôleurs | `audit.dc.services`, après confirmation (droits d’administration), budget 60 s + 25 s par contrôleur |
| AUD-008 | Comparaison d’un objet entre contrôleurs (non raccordée) | **raccordée** : `audit.dc.compare`, onglet Comparaison, objet audité de l’onglet Objet |
| AUD-009 | Analyse des identités d’une OU | `audit.identities.scan` ; **amélioré** : objets d’un constat ouverts directement (Auditer, Ouvrir la fiche), tuiles par catégorie |
| AUD-010 | Cible = objet de la fiche | `audit.target` (`?dn=` venu de la fiche), **amélioré** : recherche dans l’index local et suggestions ; nouvelle cible = résultats effacés |
| AUD-011 | Stratégie de mot de passe applicable | `audit.object.policy` |
| AUD-012 | Groupes imbriqués et cycles | `audit.object.groups` ; **amélioré** : graphe visuel des imbrications (chemin éclairé au survol) |
| AUD-013 | Pourquoi membre de ce groupe ? | `audit.object.groupPath` (sans relecture), `audit.object.membership` (confirmation du contrôleur) |
| AUD-014 | Estimation des droits d’un bénéficiaire | `audit.object.estimate` (sur les entrées lues, sans relecture) |
| AUD-015 | Inclure les groupes du bénéficiaire | `audit.object.tokenGroups` |
| AUD-016 | Liens GPO de l’objet | `audit.object.gpoLinks` ; **amélioré** : chaîne visuelle des liens (forcés, désactivés, bloqués) |
| AUD-017 | Résultat GPO appliqué (RSoP) | `audit.object.gpoApplied`, confronté aux liens lus |
| AUD-018 | Identité du poste | `audit.object.machineIdentity` ; verdict et trois sources côte à côte (annuaire, DNS, poste) |
| AUD-019 | Synthèse des relations | `audit.object.relations` (lue à l’ouverture de la vue : mémoire locale, aucune lecture réseau) |
| AUD-020 | Historique des associations | `audit.object.history` ; **amélioré** : frise chronologique et filtre par source |
| AUD-021 | Délégations (ACE) | `audit.object.acl` ; **amélioré** : colonne « À examiner » (réplication hors administrateurs, écriture large à tous) |
| AUD-022 | Totaux de la copie locale | `audit.localTotals`, au geste « Analyser le domaine », avec la date de la copie |
| AUD-023 | Vue du domaine | `audit.overview` ; **amélioré** : constats par gravité (catalogue de 25 contrôles), score de santé, comparaison avec la vue précédente, exploration des objets (`audit.finding.objects`) |

## 2. Récapitulatif

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `audit.target` | `LocalRead` | `{ dn }` | objet audité et lectures possibles (§ 4) |
| `audit.objects.search` | `LocalRead` | `{ text }` (100 caractères au plus) | 20 objets au plus (§ 4) |
| `audit.catalogue` | `Local` | aucun | contrôles de l’analyse (§ 5) |
| `audit.overview` | `NetworkRead`, servie en simulation | aucun | vue du domaine et constats (§ 5) |
| `audit.finding.objects` | `Local` | `{ id }` | objets d’un constat de la dernière analyse (§ 5) |
| `audit.localTotals` | `LocalRead` | aucun | totaux de la copie locale (§ 5) |
| `audit.dc.list` | `NetworkRead`, servie en simulation | aucun | contrôleurs (§ 6) |
| `audit.dc.probe` | `NetworkRead`, servie en simulation | `{ controllers }` (1 à 10 noms) | diagnostic et réplication (§ 6) |
| `audit.dc.services` | `NetworkRead`, servie en simulation | `{ controllers }` | services de l’annuaire (§ 6) |
| `audit.dc.compare` | `NetworkRead`, servie en simulation | `{ dn, controllers }` | comparaison d’un objet (§ 6) |
| `audit.object.policy` | `NetworkRead`, servie en simulation | `{ dn }` | stratégie de mot de passe (§ 7.1) |
| `audit.object.groups` | `NetworkRead`, servie en simulation | `{ dn }` | appartenances imbriquées (§ 7.2) |
| `audit.object.groupPath` | `Local` | `{ dn, groupDn }` | chemin d’appartenance lu (§ 7.2) |
| `audit.object.membership` | `NetworkRead`, servie en simulation | `{ dn, groupDn }` | chemin et réponse du contrôleur (§ 7.2) |
| `audit.object.acl` | `NetworkRead`, servie en simulation | `{ dn }` | délégations (§ 7.3) |
| `audit.object.estimate` | `Local` | `{ dn, sid }` | estimation de neuf droits (§ 7.3) |
| `audit.object.tokenGroups` | `NetworkRead`, servie en simulation | `{ dn, sid }` | estimation avec les groupes (§ 7.3) |
| `audit.object.gpoLinks` | `NetworkRead`, servie en simulation | `{ dn }` | liens GPO (§ 7.4) |
| `audit.object.gpoApplied` | `NetworkRead`, servie en simulation | `{ dn }` | liens et résultat RSoP (§ 7.4) |
| `audit.object.machineIdentity` | `NetworkRead`, servie en simulation | `{ dn }` | identité du poste (§ 7.5) |
| `audit.object.relations` | `LocalRead` | `{ dn }` | synthèse des associations (§ 7.6) |
| `audit.object.history` | `LocalRead` | `{ dn, limit }` (`limit` 1 à 1 000 ou `null` : 200) | historique enregistré (§ 7.6) |
| `audit.identities.scan` | `NetworkRead`, servie en simulation | `{ dn, subtree }` | constats d’identité d’une OU (§ 8) |

Les lectures réseau ne partent que sur un geste : un bouton de l’écran, ou une adresse explicite (§ 9). Les opérations
`Local` réutilisent ce que la session a déjà lu (dernière analyse, dernière liste d’accès, derniers groupes) et ne lisent
jamais l’annuaire ; avant la lecture correspondante, elles refusent avec `audit.overviewNotRead`, `audit.aclNotRead` ou
`audit.groupsNotRead`. Ces résultats sont gardés en mémoire pour la session seulement (`AuditService`), par DN : rien de
ce qui a été lu pour un objet n’est montré pour un autre.

## 3. Erreurs propres

| Code | Message | Cause |
|---|---|---|
| `audit.targetUnknown` | Objet introuvable dans l’annuaire de la session : rien n’a été lu. | DN bien formé qui ne désigne ni un objet ni la racine du domaine. |
| `audit.notApplicable` | *Motif de la lecture* (« La stratégie de mot de passe se lit pour un compte utilisateur. »…) | Lecture qui ne s’applique pas à ce type d’objet (Domenia 1 `Get-DomeniaAdAuditAvailability`). |
| `audit.overviewNotRead` | Analysez d’abord le domaine : l’exploration montre seulement les objets lus par l’analyse, sans relecture. | `audit.finding.objects` avant `audit.overview`. |
| `audit.findingUnknown` | Constat inconnu : rien n’a été lu. | Identifiant absent du catalogue. |
| `audit.aclNotRead` | Lisez d’abord les délégations de cet objet : l’estimation porte sur les entrées lues. | `estimate` ou `tokenGroups` sans `audit.object.acl` sur ce DN. |
| `audit.groupsNotRead` | Lisez d’abord les appartenances de cet objet, puis choisissez un groupe. | `groupPath` ou `membership` sans `audit.object.groups` sur ce DN. |
| `audit.trusteeUnknown` | Ce bénéficiaire ne figure dans aucune entrée lue : rien n’est estimé. | SID absent des entrées lues. |
| `audit.builtinTrustee` | Les groupes se lisent pour un compte ou un groupe d’un domaine, pas pour une identité intégrée. | `tokenGroups` pour un SID qui n’est pas `S-1-5-21-…`. |
| `audit.controllersInvalid` | Choisissez au moins un contrôleur…, Diagnostic borné à 10 contrôleurs…, Nom de contrôleur invalide : aucune lecture. | Noms vides, plus de 10 ou hors `^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$`. |
| `audit.scopeTooWide` | Le domaine entier n’est pas analysé : choisissez une OU, ou décochez « Inclure les sous-OU ». | `audit.identities.scan` sur la racine avec ses sous-OU. |
| `audit.outsideDomain` | Objet hors du domaine connecté : aucun lien à lire. | Chaîne GPO qui n’atteint pas la racine du domaine de la session. |

Communs : `arguments.invalid` (précisions du § 1.4 de `OPERATIONS.md`, plus « « controllers » doit être un tableau de 1 à
10 noms de contrôleurs. », « « sid » doit être un identifiant de sécurité (S-1-…). », « « limit » doit être un entier de 1
à 1 000 ou null. », « « id » doit être un identifiant de constat. »), `ou.unknown` (OU inconnue de l’analyse des
identités), `source.unavailable` (mode annuaire tant que `Domenia.Ad` n’est pas branché : aucun lecteur),
`simulation.unavailable` (jamais : toutes les lectures réseau de l’écran sont servies par l’annuaire fictif),
`operation.cancelled`.

## 4. Cible : `audit.target`, `audit.objects.search`

`AuditTargetView` : `dn`, `kind` (`user`, `computer`, `group`, `organizationalUnit`, `domain`, `other`), `kindLabel`
(« Utilisateur », « Ordinateur », « Groupe », « Unité d’organisation », « Domaine »), `name`, `samAccountName`,
`objectGuid` (format `D`), `sid`, `dnsHostName`, `path` (`example.local › Utilisateurs › Paris › Julien Martin`),
`description`, `availability` : pour `policy`, `groups`, `acl`, `gpoLinks`, `gpoApplied`, `machineIdentity`, `relations`,
`comparison`, un objet `{ allowed, reason }` (`reason` `null` quand la lecture s’applique).

| Lecture | Types admis | Motif sinon |
|---|---|---|
| `policy` | utilisateur | La stratégie de mot de passe se lit pour un compte utilisateur. |
| `groups` | utilisateur, ordinateur, groupe | Les appartenances se lisent pour un utilisateur, un ordinateur ou un groupe. |
| `acl`, `comparison` | tous | — |
| `gpoLinks` | utilisateur, ordinateur, OU, domaine (amélioration : le domaine) | Les liens GPO se lisent pour un utilisateur, un ordinateur, une unité d’organisation ou le domaine. |
| `gpoApplied`, `machineIdentity` | ordinateur | Le résultat appliqué se lit sur un ordinateur. · L’identité AD, DNS et poste se vérifie pour un ordinateur. |
| `relations` (et `history`) | utilisateur, ordinateur | Les associations concernent un utilisateur ou un ordinateur. |

`audit.objects.search` : tableau d’au plus 20 `AuditTargetView` dont le nom, le compte ou le nom DNS contient le texte
(sans accent ni casse) ; correspondance exacte d’abord, puis début, puis contenu ; texte vide : `[]`.

## 5. Domaine : `audit.catalogue`, `audit.overview`, `audit.finding.objects`, `audit.localTotals`

### 5.1 Catalogue des contrôles

Chaque contrôle est une recherche bornée de l’analyse (Domenia 1 « Comptes à surveiller », « Groupes privilégiés »,
stratégie, corbeille…), notée par une règle fixe (`AuditFindings.Catalogue`). Gravités : `critical` (Critique), `high`
(Élevée), `medium` (Moyenne), `low` (Faible), `info` (Information) ; un contrôle lu sans écart est `passed` (ton `ok`).

| Id | Contrôle | Gravité quand il trouve |
|---|---|---|
| `dcsyncRights` | Droits de réplication (DCSync) hors administrateurs | critique |
| `unconstrainedDelegation` | Délégation non contrainte hors contrôleurs | critique |
| `krbtgtPassword` | Mot de passe du compte krbtgt (âge en jours) | élevée au-delà de 3 ans, moyenne au-delà d’un an, faible au-delà de 180 jours |
| `constrainedDelegation` | Délégation contrainte avec transition de protocole | élevée |
| `asrepRoast` | Comptes sans pré-authentification Kerberos | élevée (critique pour un compte à privilèges) |
| `passwordNotRequired` | Mot de passe non requis (PASSWD_NOTREQD) | élevée |
| `reversibleEncryption` | Chiffrement réversible des mots de passe | élevée |
| `kerberoast` | Comptes utilisateurs avec SPN | moyenne (élevée pour un compte à privilèges) |
| `domainPasswordPolicy` | Stratégie de mot de passe du domaine (moins de 12 caractères, aucun verrouillage) | moyenne |
| `privilegedNotProtected` | Comptes à privilèges hors de « Protected Users » | moyenne |
| `passwordNeverExpires` | Mots de passe sans expiration | moyenne |
| `machineAccountQuota` | Quota de jonction de postes | moyenne s’il est supérieur à 0 |
| `staleUsers` | Comptes actifs sans connexion depuis 90 jours | moyenne |
| `lapsMissing` | Postes sans mot de passe LAPS | moyenne |
| `recycleBin` | Corbeille Active Directory désactivée | moyenne |
| `adminCountOrphans` | adminCount résiduel | faible |
| `builtinAdminActive` | Compte Administrateur intégré utilisé (connexion sous 30 jours) | faible |
| `neverLoggedUsers` | Comptes actifs jamais utilisés | faible |
| `staleComputers` | Postes actifs sans connexion depuis 90 jours | faible |
| `lapsExpired` | Mots de passe LAPS expirés | faible |
| `disabledInGroups` | Comptes désactivés encore membres de groupes | faible |
| `privilegedMembers` | Membres des groupes privilégiés | information |
| `lockedAccounts` | Comptes verrouillés (état calculé par le contrôleur) | information |
| `disabledAccounts` | Comptes désactivés | information |
| `trusts` | Approbations de domaine | information |

`audit.catalogue` renvoie ce tableau : `{ id, category, title, severity, severityLabel, tone, source, advice }` (gravité
qu’aurait le contrôle s’il trouvait un écart) ; il sert l’état « avant l’analyse » sans aucune lecture.

### 5.2 `audit.overview`

| Champ | Contenu |
|---|---|
| `readAt`, `controller`, `durationMs` | Date de l’analyse, contrôleur interrogé, durée. |
| `score` | `{ value, tone, label, detail }` : score de santé **indicatif**, 100 moins 15 par constat critique, 6 par élevé, 3 par moyen, 1 par faible ; ≥ 85 Bon, ≥ 65 Correct, ≥ 40 À améliorer, sinon Préoccupant. Un contrôle refusé n’est pas compté et `detail` le dit (« le score peut être optimiste »). |
| `counts` | `{ critical, high, medium, low, info, passed }`. |
| `findings` | Un `AuditFinding` par contrôle, dans l’ordre : constats lus par gravité puis ordre du catalogue, contrôles non lus, contrôles sans écart. |
| `sections` | Onze sections `{ id, title, icon, state, stateLabel, tone, message, items: [{ label, value, tone }] }` : `directory` (Annuaire), `fsmo`, `passwordPolicy`, `fineGrained`, `recycleBin`, `controllers`, `sites`, `trusts`, `gpo`, `privilegedGroups`, `watchlist` (Comptes à surveiller). Un refus sur une section n’empêche pas les autres. |
| `refused`, `anomalies` | Refus (sections et contrôles), sections non lues. |
| `summary` | Phrase de l’analyse. |
| `previous` | `null` à la première analyse de la session ; ensuite `{ readAt, score, delta, label }` (« Score inchangé depuis la vue précédente »). |

`AuditFinding` : `id`, `severity`, `severityLabel` (« Sans écart » pour un contrôle passé), `tone`, `category`, `title`,
`summary`, `count` (objets trouvés, ou valeur d’un contrôle scalaire : jours pour krbtgt, quota), `countLabel`, `passed`,
`state` (`read`, `empty`, `refused`, `unavailable`, `notRead`), `source`, `limit`, `advice`, `objectKind`, `explorable`,
`truncated` (la recherche a trouvé plus d’objets qu’elle n’en garde), `delta` (écart avec la vue précédente, ou `null`),
`examples` (trois noms au plus, pour la carte).

### 5.3 `audit.finding.objects`

`{ id, title, severity, severityLabel, total, shown, truncated, limit (500), readAt, summary, rows }`, lignes
`{ dn, name, kind, kindLabel, samAccountName, enabled, lastLogon, passwordLastSet, detail, container }`. Ce sont les objets
lus par la **dernière** analyse : aucune relecture.

### 5.4 `audit.localTotals`

`{ state, stateLabel, lastSyncAt, complete, simulated, total, types: [{ type, label, count, disabled }], summary }` :
totaux par type (Utilisateur, Ordinateur, Groupe, OU, Conteneur) de la copie locale, avec sa date ; jamais un dénombrement
de l’annuaire (Domenia 1 MO-04). Copie vide, absente ou occupée : dit en clair. En simulation : copie fictive de l’annuaire
en mémoire (`simulated` = `true`), aucune base ouverte.

## 6. Contrôleurs : `audit.dc.list`, `audit.dc.probe`, `audit.dc.services`, `audit.dc.compare`

- `audit.dc.list` : `{ controllers: [{ dnsName, name, site, operatingSystem, roles, pdc, readOnly, dn }], pdc, truncated, summary, readAt }`.
- `audit.dc.probe` : `{ rows, neighbors, facts, summary, readAt }`. Ligne : `controller`, `verdict` (`clear`, `check`,
  `notRead`), `verdictLabel`, `tone`, `ldap`, `kerberos`, `reach`, `time`, `skewSeconds`, `synchronized`, `replication`,
  `failures`, `dns`, `reasons`, `detail`. Lien : `controller`, `partner`, `partition`, `lastSuccess`, `lastSuccessLabel`
  (« Jamais » pour 1601), `lastAttempt`, `lastAttemptLabel`, `result` (« 1722 (serveur RPC non disponible) »), `failures`,
  `never`, `tone`. Seuils : 300 s d’écart d’heure, 24 h sans succès de réplication. Un contrôleur injoignable est « Non lu ».
- `audit.dc.services` : `{ rows: [{ controller, service, state, startMode, finding, tone }], skipped, budgetSeconds, summary, readAt }`.
  NTDS, Netlogon, Kdc, W32Time, ADWS attendus démarrés ; DNS absent « normal si le DNS est hébergé ailleurs » ; DFSR ou NtFrs
  réplique SYSVOL. La page demande confirmation (droits d’administration) ; un refus signale un manque de droits.
- `audit.dc.compare` : `{ dn, name, controllers, rows: [{ attribute, identical, values: [{ controller, value, version, changedAt, origin }] }], differences, comparable, notRead, note, summary, readAt }`.
  Les USN, locaux à chaque contrôleur, ne sont jamais comparés.

## 7. Objet

### 7.1 `audit.object.policy`

`{ dn, state (applies, none, unreadable), policyKnown, summary, facts, expiresAt, controller, readAt }`. msDS-ResultantPSO
décide ; la stratégie du domaine n’est présumée que si des stratégies fines sont visibles et qu’aucune ne vise le compte ;
sinon elle n’est montrée qu’« en référence ». Une durée absente n’est jamais « sans limite ». Aucun mot de passe n’est lu.

### 7.2 `audit.object.groups`, `audit.object.groupPath`, `audit.object.membership`

`audit.object.groups` : `{ dn, rows, cycles, unread, primaryGroup, truncated, direct, nested, maxDepth, privileged, summary, graph, controller, readAt, elapsedMs }`.
Ligne : `dn`, `name`, `depth`, `via` (« Appartenance directe », « Par GG-Support-N2 »), `path` (noms de l’objet au groupe),
`state` (« Lu », « Non lu : … », « Lu partiellement : plus de 1 500 appartenances… »), `tone`, `cycle`, `privileged`.
`graph` : `{ nodes: [{ id, label, depth, kind (start, group, primary), privileged, cycle, unread }], edges: [{ from, to, cycle }] }`.
Bornes : 2 000 groupes, 16 niveaux, 10 s, 20 cycles ; une lecture bornée ne prouve jamais une absence.

`audit.object.groupPath` et `audit.object.membership` : `{ dn, groupDn, groupName, member (true, false, null), certain, path, text, confirmed, error }`.

### 7.3 `audit.object.acl`, `audit.object.estimate`, `audit.object.tokenGroups`

`audit.object.acl` : `{ dn, state, stateLabel, owner, ownerSid, protected, total, truncated, maxAces (1 000), explicit, inherited, deny, rows, trustees, summary, limit, controller, readAt }`.
Ligne : `index`, `trustee`, `sid`, `allow`, `type`, `rights` (en français), `target`, `appliesTo`, `origin`, `scope`,
`explicit`, `onObject`, `domainAccount`, `risk` (amélioration : « Réplication de l’annuaire hors administrateurs (DCSync) »,
« Écriture large accordée à tous les comptes », ou `null`).

`audit.object.estimate` et `audit.object.tokenGroups` : `{ dn, sid, trustee, includesGroups, groupsState, groupsMessage, groupCount, rows: [{ id, label, result (allowed, denied, partial, notGranted), resultLabel, tone, decidedBy }], limits, summary }`.
Neuf droits (contrôle total, lire, modifier des attributs, réinitialiser le mot de passe, modifier les membres, créer,
supprimer, modifier les autorisations, changer le propriétaire) ; ordre canonique, refus prioritaire ; une estimation,
jamais un droit effectif.

### 7.4 `audit.object.gpoLinks`, `audit.object.gpoApplied`

`{ dn, chain, rows, facts, linksRead, appliedProven, rsopState, computer, summary, linksReadAt, rsopReadAt }`. Ligne :
`name`, `guid`, `linkedTo`, `linkedToDn`, `link`, `enforced`, `inheritance`, `expected` (Oui, Non, Indéterminé),
`outcome` (`applied`, `notApplied`, `filtered`, `disabled`, `unproven`), `result`, `resultState`, `proof`, `gpoStatus`, `tone`.
Une GPO n’est dite appliquée que si RSOP_GPLink lui donne un ordre d’application ; une réponse RSoP vide ou partielle n’est
jamais « rien d’appliqué ». Les deux lectures se complètent : la seconde reprend la première si elle a eu lieu.

### 7.5 `audit.object.machineIdentity`

`{ dn, state (coherent, unverified, incoherent), stateLabel, tone, summary, reasons, warnings, facts, address, expected, reported, readAt }`.
Rien n’est attribué, fusionné ni renommé ; incohérente : aucune observation ni relation attribuée.

### 7.6 `audit.object.relations`, `audit.object.history`

`audit.object.relations` : `{ dn, applicable, lines: [{ fact, value, badge, badgeLabel, rule }], declared, observed, history, text }`
(Affectation déclarée, Dernière session observée, Historique, Autres indices ; jamais de jointure entre GUID différents).

`audit.object.history` : `{ dn, state, stateLabel, total, shown, limit, rows: [{ at, dateLabel, user, computer, nature, badge, rule, source, verifiedInAd, details }], summary }` ;
la présence dans l’historique ne prouve pas une session actuelle ; aucun pourcentage de fiabilité.

## 8. Identités : `audit.identities.scan`

`{ baseDn, path, subtree, limit (5 000), objects, truncated, findings, categories, localIndex, localIndexText, summary, controller, readAt }`.
Constat : `{ id, category, element, objects: [{ name, dn }], objectsText, conclusion (« À revoir »), limit, tone }`.
Catégories : Valeur en double (adresse, nom de connexion, matricule), Nom DNS partagé, Nom AD et nom DNS divergents, Nom
recyclé ou objet recréé (comparaison avec la copie locale, 1 000 noms de chaque type ; le nombre comparé est dit). Le
domaine entier avec ses sous-OU est refusé.

## 9. Page (`web/js/pages/audit.js`, `web/js/pages/audit/*.js`)

Onglets : Synthèse, Objet, Contrôleurs, Identités. Paramètres de l’adresse : `tab` (`synthese`, `objet`, `controleurs`,
`identites`), `dn` (objet audité : la fiche ouvre `#/audit?dn=…`), `vue` (`motdepasse`, `groupes`, `delegations`, `gpo`,
`poste`, `relations`), `groupe` (groupe expliqué après la lecture des groupes), `constat` (constat exploré après
l’analyse), `ou` (OU des identités), et `lancer` : **geste explicite porté par l’adresse** (lien d’un autre écran, palette,
captures) qui lance la lecture du bouton de l’onglet, une fois : `analyse` (Synthèse), `1` (Objet : la lecture de la vue ;
Identités : l’analyse de l’OU), `liste` ou `diagnostic` (Contrôleurs). Le paramètre est retiré de l’adresse après usage.

Composants locaux (le kit n’en a pas) : graphe des imbrications (`audit/graph.js`), bandeau de gravités, cartes de constats,
échelle des liens GPO, tuiles de contrôleurs. Les panneaux latéraux de l’écran portent `data-page="audit"` pour garder la
feuille de style de l’écran hors de `.main`.

## 10. Simulation

Données dérivées de l’annuaire fictif tel que la session le voit (`CurrentDirectory`, écritures comprises) et de données
fixes (`SimulatedAuditData`) ; ce que l’annuaire ne porte pas vient du sous-flux `screen/audit`. Délais réalistes et
annulables par sorte (`latency/screen/audit/<sorte>`). Constats de la graine par défaut : `svc-annuaire` a les droits de
réplication sur la racine (critique), `svc-web` une délégation contrainte avec transition de protocole, krbtgt inchangé
depuis la création du domaine, 5 comptes de service avec SPN, quota de jonction à 10, 16 mots de passe sans expiration,
Administrateur hors de Protected Users, 4 `adm-…` avec adminCount résiduel, 23 postes sans LAPS ; DC02 a un lien de
réplication en échec (1722, ForestDnsZones, 26 h) et ADWS arrêté. Deux stratégies fines (`PSO-Comptes-a-privileges` sur
GG-Admins-Postes et GG-Admins-Serveurs, donc Julien Martin par GG-Support-N2 ; `PSO-Comptes-de-service`). Seize GPO et leurs
liens (Sécurité de base forcée sur Postes, blocage d’héritage sur Quarantaine, BitLocker filtré sur les postes fixes, GPO de
site visible seulement dans RSoP). Les postes qui n’ont pas répondu au relevé de présence ne répondent ni à RSoP ni à CIM ;
deux postes répondent sous le nom d’un autre (identité incohérente). La copie locale fictive associe un ou deux noms de
chaque OU analysée à un autre GUID (objets recréés).

## 11. Mode annuaire (vague 3)

`Domenia.Ad` fournira un `AdAuditReader : IAuditReader` qui construit les mêmes lectures brutes (`AuditReads.cs`), puis les
mêmes règles s’appliquent. Toutes les lectures partent du fil de travail, avec la garde d’authentification (un refus
d’authentification suspend le compte, comme `Register-WCredentialFailure`), sans mot de passe ni jeton dans un journal ou un
argument de processus. Messages d’erreur coupés à 300 caractères.

| Lecture | Requête | Attributs | Bornes |
|---|---|---|---|
| Cible, recherche | Index local (base SQLite, `ad_objects`) | GUID, DN, type, nom, compte, nom DNS | 20 résultats ; jamais le réseau |
| Vue du domaine : RootDSE | `LDAP://<contrôleur>/RootDSE` | `defaultNamingContext`, `configurationNamingContext`, `schemaNamingContext`, `rootDomainNamingContext`, `dnsHostName`, `serverName`, `domainFunctionality`, `forestFunctionality`, `domainControllerFunctionality`, `highestCommittedUSN`, `currentTime`, `namingContexts` | 90 s pour toute l’analyse ; une section refusée n’arrête pas les autres |
| Rôles FSMO | racine, schéma, `CN=Partitions,<config>`, `CN=RID Manager$,CN=System`, `CN=Infrastructure` | `fSMORoleOwner`, `rIDAvailablePool` (RID restants = total − alloués) | une lecture par objet |
| Stratégie du domaine | racine du domaine | `minPwdLength`, `pwdHistoryLength`, `maxPwdAge`, `minPwdAge`, `lockoutThreshold`, `lockoutDuration`, `lockOutObservationWindow`, `pwdProperties`, `ms-DS-MachineAccountQuota` | — |
| Stratégies fines | `CN=Password Settings Container,CN=System`, `(objectClass=msDS-PasswordSettings)`, un niveau | `name`, `msDS-PasswordSettingsPrecedence`, `msDS-MinimumPasswordLength`, `msDS-LockoutThreshold`, `msDS-PSOAppliesTo` | 50 |
| Corbeille | `CN=Partitions,<config>` ; `CN=Deleted Objects`, `(isDeleted=TRUE)`, contrôle *tombstone* | `msDS-EnabledFeature`, `name` | 25 objets supprimés |
| Contrôleurs | `(&(objectCategory=computer)(|(userAccountControl:1.2.840.113556.1.4.803:=8192)(userAccountControl:1.2.840.113556.1.4.803:=67108864)))` | `name`, `dNSHostName`, `operatingSystem`, `serverReferenceBL` (site), `userAccountControl`, `distinguishedName` | 100 (101 demandés pour dire la troncature) |
| Sites, sous-réseaux | `CN=Sites,<config>` `(objectClass=site)` ; `CN=Subnets,CN=Sites,<config>` `(objectClass=subnet)` | `name`, `description`, `siteObject` | 200 sites, 500 sous-réseaux |
| Approbations | `CN=System`, `(objectClass=trustedDomain)`, un niveau | `name`, `trustDirection`, `trustType`, `trustAttributes`, `flatName` | 100 |
| GPO | `CN=Policies,CN=System`, `(objectClass=groupPolicyContainer)`, un niveau | `displayName`, `versionNumber`, `whenChanged`, `flags` | 500 |
| Groupes privilégiés | groupes par SID : `-512`, `-518`, `-519`, `S-1-5-32-544/548/549/550/551` | `member` (et membres imbriqués lus par `LDAP_MATCHING_RULE_IN_CHAIN` `1.2.840.113556.1.4.1941`) | 5 groupes par nom, 12 noms affichés |
| `dcsyncRights` | `nTSecurityDescriptor` de la racine (`SecurityMasks` Owner + Dacl) | entrées `ExtendedRight` 1131f6aa, 1131f6ad, 89e95b76 hors S-1-5-9, `-498`, `-512`, `-516`, `-519`, `-521`, S-1-5-32-544, S-1-5-18 | 1 000 entrées |
| `unconstrainedDelegation` | `(&(|(objectCategory=person)(objectCategory=computer))(userAccountControl:1.2.840.113556.1.4.803:=524288)(!(userAccountControl:1.2.840.113556.1.4.803:=8192)))` | `name`, `sAMAccountName`, `lastLogonTimestamp` | 60 |
| `constrainedDelegation` | `(&(msDS-AllowedToDelegateTo=*)(userAccountControl:1.2.840.113556.1.4.803:=16777216))` | `msDS-AllowedToDelegateTo` | 60 |
| `asrepRoast` | `(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=4194304))` | `adminCount` | 60 |
| `kerberoast` | `(&(objectCategory=person)(objectClass=user)(servicePrincipalName=*)(!(sAMAccountName=krbtgt)))` | `servicePrincipalName`, `adminCount` | 60 |
| `passwordNotRequired`, `reversibleEncryption`, `passwordNeverExpires`, `disabledAccounts` | filtres `userAccountControl:…:=32`, `=128`, `=65536`, `=2` (actifs : `(!(userAccountControl:…:=2))`) | `name`, `sAMAccountName` | 60 (200 pour les désactivés) |
| `krbtgtPassword` | `(sAMAccountName=krbtgt)` | `pwdLastSet` | 1 |
| `staleUsers`, `neverLoggedUsers`, `staleComputers` | `lastLogonTimestamp<=<FILETIME de J−90>` ou absent (`!(lastLogonTimestamp=*)`), comptes actifs | `lastLogonTimestamp`, `whenCreated` | 200 |
| `lapsMissing`, `lapsExpired` | postes actifs sans `msLAPS-PasswordExpirationTime` ni `ms-Mcs-AdmPwdExpirationTime`, ou date dépassée | dates d’expiration seulement, jamais un mot de passe | 200 |
| `privilegedNotProtected`, `adminCountOrphans` | `(adminCount=1)` et membres de `-525` (Protected Users) par la règle in-chain | `memberOf`, `adminCount` | 200 |
| Totaux de la copie | base locale (lecture seule, attente courte 250 ms) | `ad_objects` par type et état, `sync_state.last_sync` | aucune lecture réseau |
| Diagnostic des contrôleurs | `Dns.GetHostAddresses`, TCP 389 et 88 (0,5 à 3 s), `Resolve-DnsName _ldap._tcp.dc._msdcs.<domaine>` (SRV), RootDSE du contrôleur : `currentTime`, `isSynchronized`, `isGlobalCatalogReady`, `highestCommittedUSN`, `msDS-ReplAllInboundNeighbors` (XML sans DTD) | — | 1 à 10 contrôleurs, 120 s |
| Services | CIM DCOM (`System.Management`), `Win32_Service` filtré sur NTDS, Netlogon, Kdc, W32Time, ADWS, DNS, DFSR, NtFrs ; `Name`, `State`, `StartMode` | session 10 s, requête 15 s | budget 60 s + 25 s par contrôleur (300 s au plus), 20 s de marge ; contrôleurs non interrogés dits |
| Comparaison | lecture de l’objet sur chaque contrôleur choisi | attributs de la fiche et `msDS-ReplAttributeMetaData` (XML sans DTD) | 10 contrôleurs |
| Stratégie de mot de passe | objet utilisateur (`RefreshCache`) | `userAccountControl`, `msDS-User-Account-Control-Computed`, `pwdLastSet`, `msDS-UserPasswordExpiryTimeComputed`, `msDS-ResultantPSO` ; PSO désignée : attributs `msDS-*` ; nombre de PSO visibles | 45 s ; repli sur les attributs simples si `msDS-ResultantPSO` est refusé (raison gardée) |
| Groupes imbriqués | `memberOf` de l’objet puis de chaque groupe ; `primaryGroupID` → groupe par SID ; confirmation : `(member:1.2.840.113556.1.4.1941:=<DN>)` sur le groupe | `memberOf`, `name`, `objectSid`, `adminCount`, plage de `member` | 2 000 groupes, 16 niveaux, 10 s |
| Délégations | `nTSecurityDescriptor` (Owner + Dacl, jamais Sacl) ; noms des SID par lots de 40 (`objectSid`), GUID par lots de 20 dans le schéma (`schemaIDGUID`) et `CN=Extended-Rights` (`rightsGuid`) | — | 1 000 entrées (10 à 5 000), 400 SID, 120 GUID, 60 s |
| tokenGroups | `<SID=…>` | `tokenGroups`, `sAMAccountName` | SID de domaine seulement, 30 s |
| Liens GPO | chaque conteneur de la chaîne (`RefreshCache`) puis `CN=Policies,CN=System` par `cn` | `gPLink`, `gPOptions` ; `cn`, `displayName`, `flags`, `whenChanged` | 40 conteneurs, 200 GPO, 45 s ; liens de site non lus (dit) |
| RSoP | CIM `root\rsop\computer` : `RSOP_GPO` (`name`, `guidName`, `id`, `accessDenied`, `filterAllowed`, `enabled`), `RSOP_GPLink` (`GPO`, `SOM`, `appliedOrder`) | — | 30 s par requête, 90 s ; pas de gpresult, d’appel de méthode ni d’actualisation |
| Identité du poste | DNS direct (IPv4) et inverse, CIM `Win32_ComputerSystem` (`Name`, `Domain`, `DNSHostName`) | — | session 15 s, requête 20 s, 60 s |
| Relations, historique | mémoire de la session et base locale `user_machine_history` (`user_login`, `computer_key`, `computer`, `source`, `verified_in_ad`, `observed_at`, `details`, `user_guid`, `computer_guid`) | lecture seule, attente 250 ms, base réseau refusée | 200 lignes (1 000 au plus) |
| Identités d’une OU | `(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer))` sur l’OU (un niveau ou sous-arbre) ; noms comparés dans la base locale (`ResolveNames`) | `objectGUID`, `name`, `sAMAccountName`, `userPrincipalName`, `mail`, `employeeID`, `dNSHostName`, `objectClass`, `userAccountControl`, `lastLogonTimestamp`, `pwdLastSet`, `description`, `department`, `manager`, `whenCreated`, `distinguishedName` | 5 000 objets (100 à 20 000), 1 000 noms de chaque type, 120 s ; racine avec sous-OU refusée |

Classes en mode annuaire : inchangées (`NetworkRead` pour toute lecture de l’annuaire, du DNS ou d’un poste, `LocalRead`
pour la base locale et l’index, `Local` pour les calculs sur ce qui a été lu).

## 12. Tests (écrits, non exécutés)

`tests/Domenia.Tests/AuditTests.cs` : registre (classes, servies en simulation, aucune écriture), refus en mode annuaire
sans lecteur, formes JSON exactes, catalogue sans lecture, analyse (gravités, score, vue précédente), exploration sans
relecture, totaux de la copie, contrôleurs (verdicts, refus de plus de 10 noms et des noms invalides), services, stratégie de
mot de passe (PSO par imbrication), groupes et « pourquoi membre », délégations (DCSync, refus, AdminSDHolder),
estimation, GPO, identités (domaine entier refusé), et règles pures (cycles, gPLink, refus prioritaire, stratégie illisible,
poste incohérent, score, chaîne GPO, XML sans DTD). Scénarios E2E : `tests/e2e/audit/*.json` ([`E2E.md`](../E2E.md)).

**Intégration** : `PlatformTests.SimulationOperations` et la liste des modules attendus (`Modules_of_the_bridge_are_found…`)
énumèrent le registre exact ; ils devront recevoir les 23 opérations `audit.*` et `AuditOperations` à la fusion des écrans.
