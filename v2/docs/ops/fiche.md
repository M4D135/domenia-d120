# Écran « Fiche » — contrat des opérations

Module `FicheOperations` (`src/Domenia.Bridge/Operations/FicheOperations.cs`), écran `fiche`, route `#/fiche?dn=…`.
Lecteur : `IFicheReader` (`src/Domenia.Core/Screens/Fiche`), implémenté en simulation par `SimulatedFicheReader`.
Écritures : exécuteurs `IObjectUpdateExecutor`… (`src/Domenia.Core/Writes/Objects/ObjectWrites.cs`), circuit de `WRITES.md`.
Parité : `FIC-001` à `FIC-050` et lot R40 (fiche d’appel, `Domenia-CallSheet.*`). État : `docs/status/fiche.json`.

## 1. Règles communes

- **Classes.** Les lectures de l’objet (`fiche.read`, `fiche.attributes`, `fiche.groups`…) sont `LocalRead` en simulation
  et `NetworkRead` en mode annuaire. Les lectures sur geste (`fiche.rights`, `fiche.lockouts`, `fiche.logonByDc`,
  `fiche.presence`, `fiche.callSheet.read`) sont `NetworkRead` dans les deux modes, servies par l’annuaire fictif
  (`ServedInSimulation`). Les plans (`fiche.*.plan`) lisent seulement : la seule écriture est `write.execute`.
- **Lecture seule par défaut.** Rien ne part sur le réseau sans geste : l’ouverture d’une fiche lit l’objet seul
  (une requête de base ; le nombre d’enfants d’une OU vient de l’index local), jamais ses groupes imbriqués, ses
  verrouillages, ses droits ni sa présence. L’onglet d’arrivée suit le type (`landing`, Get-DomeniaLandingView) : un groupe
  s’ouvre sur ses membres et une OU sur son contenu, comme dans Domenia 1, ce qui lit ces listes à l’ouverture.
- **États de route.** Un paramètre `open` qui lirait le réseau (`lockouts`, `logonByDc`, `rights`, `presence`, `nested`,
  `why`, `triage`, `move`, `compare`) montre et met en valeur la carte et son bouton seulement : la lecture attend le clic.
  En simulation (aucun réseau réel), `run=1` déclenche la lecture pour les captures. `open`, `run` et `other` sont retirés
  de l’adresse dès le premier affichage (un retour arrière ne les rejoue pas).
- **Configuration.** `Security.*` et `CallSheet.TicketTemplate` de `Domenia.config.json` sont lus par
  `FicheSettingsFileReader` (Store, une fois, hors du fil de l’interface) : `AllowRawAttributeWrite`,
  `BlockSensitiveRawAttributes`, `AllowContainerDelete`, `RequireTypedDeleteConfirmation`, `RequireTypedHighRiskConfirmation`,
  `ForcePasswordChangeOnReset`, `GeneratedPasswordLength` (14 à 64), `SecretMemorySeconds`, `AutoClearSecretClipboardSeconds`.
  Mêmes règles que `LegacyConfiguration` (noms sans casse, doublon = fichier ignoré, booléens JSON seulement, nombres bornés).
  Valeurs par défaut de Domenia 1 pour ce que le fichier ne règle pas ; en simulation, une écriture brute non réglée est
  ouverte sur l’annuaire fictif. La provenance de chaque réglage est rendue (`settings`, `rawWrite.settings`).
- **Arguments.** Objet JSON fermé (propriété inconnue refusée), DN conformes à la RFC 4514 (2 048 caractères au plus),
  textes de 256 caractères au plus (`text`, `other`), valeurs d’attribut de 4 096 caractères au plus.
- **Aperçu puis lecture (FIC-030, FIC-035).** La page appelle `fiche.preview` (base locale, immédiat, marqué
  « Aperçu local · valeurs du JJ/MM/AAAA HH:mm, relecture en cours ») puis `fiche.read` qui le remplace. Dès qu’une
  lecture de l’annuaire a abouti ou échoué, un aperçu arrivé plus tard est ignoré (jamais dessiné par-dessus).
- **Identité vérifiée (FIC-033).** Le GUID de l’aperçu, ou celui de la route (`guid`), doit être celui de la lecture.
  Sinon la fiche reste indisponible, comme dans Domenia 1 (Assert-DomeniaObjectResultIdentity) : état bloquant « Objet
  remplacé depuis la sélection (GUID différent) », GUID attendu et GUID relu, sans aucune action sur l’objet relu. Les
  gestes proposés sont « Rechercher un objet » et « Ouvrir l’objet relu » (choix explicite : la fiche de l’objet relu
  s’affiche alors, et ses relectures acceptent ce GUID).
- **Déplacement (FIC-018).** Quand le reçu de `fiche.move.plan` vaut `applied` ou `noChange`, la page ouvre le nouveau DN
  (RDN de l’objet + DN de destination) avec le GUID de l’objet : la relecture vise l’objet déplacé, jamais l’ancien DN.
  Une relecture qui échoue après une écriture appliquée ne dit jamais « Rien n’a été modifié ».
- **Rafraîchissement partiel (FIC-031).** `signature` résume identité, états, appartenances et liens : à signature égale,
  la page ne repeint que les champs d’affichage.
- **Invalidation ciblée (FIC-037, FIC-046).** Le moteur garde par session la dernière lecture de chaque objet ; quand une
  lecture montre un autre `uSNChanged` ou un autre DN, seules les lectures rangées sous ce GUID sont oubliées. Les relevés
  de présence, de sessions et d’inventaire d’un poste sont rangés sous son `objectGUID` (un poste recréé ou renommé
  n’hérite pas du relevé de l’ancien). `FicheSession.Forget(dn, guid)` retire toutes les clés de l’objet (GUID avec ou
  sans tirets, DN à défaut) et rend le nombre d’entrées retirées.
- **Présence mesurée depuis la fiche.** Après « Vérifier la présence », la tuile de l’en-tête, le point de présence de
  l’avatar et la fraîcheur « Présence réseau » suivent le nouveau relevé sans autre lecture.
- **Racine du domaine.** Elle s’ouvre en fiche (accès rapides, fil du DN, « Ouvrir le parent » d’un objet placé
  directement sous elle) ; seule la racine elle-même n’a pas de parent à ouvrir. Sa suppression reste refusée.
- **Secrets.** Aucun attribut sensible n’est lu ni renvoyé (`unicodePwd`, `ms-Mcs-AdmPwd`, `msLAPS-Password`,
  `msFVE-RecoveryPassword`…). Le mot de passe d’une réinitialisation se saisit (deux fois, champs révélables) ou se génère
  (`TemporaryPassword`, longueur de la configuration, révélé une fois pour être lu) dans la **fenêtre sécurisée native de
  l’hôte** (`IFichePasswordWindow`, servie par Domenia.App) : `SecureString` de bout en bout, remise à l’exécuteur pour un
  seul plan (`IPasswordResetExecutor.Hold`), prise une fois à l’exécution puis effacée. Il ne figure jamais dans la page, un
  plan, un reçu, un journal ni un argument. Sans fenêtre (tests, exécutions sans bureau), la réinitialisation est refusée.

### 1.1 Erreurs propres à l’écran

| Code | Message | Cause |
|---|---|---|
| `fiche.unknown` | Objet introuvable dans l’annuaire : rien n’a été lu. | DN absent (supprimé, déplacé, autre domaine). |
| `fiche.notFound` | Aucun objet de la base locale ne correspond exactement : lancez une recherche globale. Rien n’a été lu sur le réseau. | `fiche.resolve` sans correspondance exacte. |
| `fiche.ambiguous` | Plusieurs objets correspondent : précisez le nom… | Nom affiché porté par plusieurs objets. |
| `fiche.notApplicable` | (précision selon l’opération) | Membres d’un utilisateur, comparaison d’un groupe, présence d’une OU, expiration d’un poste… |
| `fiche.protected` | … suppression interdite / bloquée. Aucune écriture préparée. | Racine, conteneur par défaut, objet système, `adminCount = 1`, OU sans `Security.AllowContainerDelete`. |
| `fiche.refused` | (règle SE-02, doublon d’OU, suppression récursive…) | Règle de sécurité ou d’unicité, avant tout plan. |
| `fiche.invalid` | (précision) | Nom d’OU invalide, compte comparé à lui-même… |
| `fiche.cancelled` | Fenêtre sécurisée fermée sans mot de passe : rien n’a été préparé ni envoyé. | Réinitialisation annulée dans la fenêtre de l’hôte. |
| `write.nothingToDo` | … aucune écriture à préparer. | Valeur déjà en place (circuit d’écriture, `WRITES.md`). |

Plus les codes communs (`arguments.invalid`, `source.unavailable`, `operation.cancelled`) d’`OPERATIONS.md` § 1.4.

## 2. Lectures

| Opération | Classe (simulation / annuaire) | Arguments | Résultat |
|---|---|---|---|
| `fiche.preview` | LocalRead | `dn` | `FicheSheet` marqué `origin.preview = true`, ou `null` sans projection locale. |
| `fiche.read` | LocalRead / NetworkRead | `dn`, `reread?` | `FicheSheet` : `identity`, `origin`, `states`, `band`, `sections`, `edit`, `account`, `counts`, `freshness` (durée du profil d’usage, dernière tentative), `manager`, `linked`, `presence`, `actions`, `tabs`, `landing`, `summary`, `support` (source, lecteur, date de chaque fait), `signature`, `settings`. `reread = true` oublie d’abord le cache de ce seul objet (FIC-039). |
| `fiche.resolve` | LocalRead | `text` | `FicheSummary` désigné exactement par GUID (toutes formes), SID, identifiant, `DOMAINE\compte` (domaine de la session seulement, un autre est refusé), UPN, nom ou DN. |
| `fiche.pick` | LocalRead | `text`, `kinds?` | 20 objets au plus dont le nom, le compte ou l’UPN contient le texte (sélecteurs d’objets). |
| `fiche.recent` | LocalRead | — | Dernières fiches (préférence `fiche.recent`, 12 au plus), existence revérifiée. |
| `fiche.recent.add` / `.clear` | LocalWrite | `dn` / — | Liste à jour ; un échec disque est journalisé, la liste reste en mémoire. |
| `fiche.attributes` | LocalRead / NetworkRead | `dn` | `FicheRawAttributes` : lignes triées, dates converties, syntaxe, attribut modifiable ou motif du blocage, règle d’écriture brute en vigueur. |
| `fiche.groups` | LocalRead / NetworkRead | `dn` | `FicheGroupList` : groupes directs (`memberOf`, 2 000 au plus), groupe principal (`primaryGroupID`), privilèges. |
| `fiche.groups.nested` | LocalRead / NetworkRead | `dn` | `FicheNestedList` : groupes imbriqués, niveau, groupe direct « via », troncature. |
| `fiche.groups.why` | LocalRead / NetworkRead | `dn`, `group` | `FicheWhy` : directe, chemin d’imbrication, groupe principal, réponse transitive du contrôleur quand aucun chemin n’est lu (`basis = controller`) ou indéterminé. |
| `fiche.groups.delta` | Local | `dn`, `current`, `add`, `remove` | `FicheGroupDelta` : un pas par groupe, notes, jamais la liste complète. |
| `fiche.groups.delta.check` | LocalRead / NetworkRead | `dn`, `steps` (64 au plus : `action`, `group`) | `FicheDeltaCheck` : chaque étape comparée au `memberOf` relu sur le contrôleur (Vérifié, Échec, À vérifier), synthèse Vérifié, Partiel, À vérifier ou Aucun changement. |
| `fiche.members` | LocalRead / NetworkRead | `dn` | `FicheMemberList` : membres d’un groupe lus par plages (`mode = members`, 2 000 gardés, 50 000 comptés, `complete` et `note` d’une lecture partielle) ou contenu d’une OU (`children`), types résolus par DN exact dans la base locale. |
| `fiche.destinations` | LocalRead / NetworkRead | `dn` (null : haut du domaine) | OU et conteneurs par défaut d’un niveau (`CN=Users`, `CN=Computers`… jamais `CN=Builtin`), pour le sélecteur du déplacement. |
| `fiche.relations` | LocalRead | `dn` | Responsable, équipe, `managedBy`, objets gérés, associations comptes ↔ postes avec badge et règle. |
| `fiche.history` | LocalRead / NetworkRead | `dn` | Dates lues, métadonnées de réplication, reçus Domenia de l’objet, changements de groupes vus dans la session. |
| `fiche.compare` | LocalRead / NetworkRead | `dn`, `other` | `FicheComparison` de deux utilisateurs, avec le texte pour le ticket (FIC-006). |
| `fiche.rights` | NetworkRead (servie) | `dn` | `FicheRights` : dix capacités, l’entrée décisive de chacune, rapport copiable. |
| `fiche.lockouts` | NetworkRead (servie) | `dn`, `hours?` (1 à 720, 168 par défaut) | Verrouillages 4740, rapprochement des refus de la protection des comptes de Domenia (`IFicheReader.RefusalsAsync`, 120 s, FIC-045), rapport. |
| `fiche.logonByDc` | NetworkRead (servie) | `dn` | `lastLogon`/`logonCount` par contrôleur, couverture « n lus sur m ». |
| `fiche.presence` | NetworkRead (servie) | `dn` | Ping du poste, ou du poste associé le plus fiable d’un compte (FIC-046). |
| `fiche.callSheet` | LocalRead | `dn`, `computer?` | `FicheCallSheet` construite sans réseau ; `computer` choisit le poste du tri ; texte du ticket depuis `CallSheet.TicketTemplate` quand il est utilisable (`templateSource`, `templateWarning`). |
| `fiche.callSheet.read` | NetworkRead (servie) | `dn`, `read` (`lockouts`, `policy`, `presence`, `sessions`, `triage`), `computer?` | Lecture explicite puis fiche d’appel à jour. |

## 3. Plans d’écriture

Chaque plan renvoie `{ plan, token }` (`WRITES.md` § 3) ; l’exécution passe par `write.execute`, une seule fois, avec reçu
et relecture. En mode annuaire, tant que `Domenia.Ad` n’est pas branché, les actions d’écriture sont affichées
indisponibles avec leur motif.

| Opération | Arguments | Type d’écriture | Garde |
|---|---|---|---|
| `fiche.update.plan` | `dn`, `fields` (attribut → texte ou `null`) | `object.update` | Champs enregistrables du type, seuls les champs changés, `null` = effacement explicite. |
| `fiche.enable.plan` | `dn`, `enabled` | `account.enabled` | Désactivation : risque fort ; compte protégé : nom à saisir. |
| `fiche.expiration.plan` | `dn`, `date` (`aaaa-mm-jj` ou `null`) | `account.expiration` | Début du jour local, relu et comparé au jour local. |
| `fiche.expirePassword.plan` | `dn` | `password.expire` | `pwdLastSet = 0`, le mot de passe actuel n’est pas modifié. |
| `fiche.options.plan` | `dn`, `options` (id → booléen) | `account.options` | Bits changés seulement ; option à risque activée : nom à saisir. |
| `fiche.rawAttribute.plan` | `dn`, `attribute`, `value?` | `attribute.raw` | SE-02 avant le plan puis dans l’exécuteur, avec la politique du plan (`Remember`) ; attributs opérationnels refusés. |
| `fiche.move.plan` | `dn`, `target`, `guid?` | `object.move` | OU ou conteneur du domaine ; GUID capturé à l’ouverture du sélecteur et revérifié (objet changé : refus) ; nouveau DN relu ; références des groupes suivies. |
| `fiche.membership.plan` | `group`, `member`, `add` | `group.member` | Un groupe par plan ; groupe à privilèges : nom à saisir ; relu des deux côtés. |
| `fiche.delete.plan` | `dn` | `object.delete` | Non récursive ; la page demande d’abord le mot SUPPRIMER, le plan le nom exact (`RequireTypedDeleteConfirmation`) ; racine/conteneurs/objets système/protégés refusés, OU selon `AllowContainerDelete` ; absence relue ; associations locales retirées après la suppression. |
| `fiche.createOu.plan` | `parent`, `name` | `ou.create` | 1 à 64 caractères, unicité sous le parent, parent revérifié. |
| `fiche.resetPassword.plan` | `dn`, `mustChange`, `unlock`, `generate?`, `theme?` | `password.reset` | Le moteur ouvre la fenêtre sécurisée de l’hôte pendant la préparation (saisie ou génération), puis remet le `SecureString` à l’exécuteur pour ce plan seul ; compte protégé permis avec la saisie du nom (Domenia 1) ; fenêtre fermée : `fiche.cancelled`. |

## 4. Simulation

- Le monde de la fiche (`SimulatedFicheWorld`) dérive de l’annuaire fictif : OU, conteneurs, utilisateurs, postes,
  groupes, plus 18 contacts dans `OU=Distribution` et des attributs de profil (adresse, téléphones, profil, script,
  heures d’ouverture, postes autorisés, SPN) tirés de la graine.
- Les écritures passent par la surcouche `SimulatedDirectoryOverlay` (utilisateurs, postes, groupes, OU, suppressions) :
  toutes les lectures de l’application les voient ; les attributs hors du modèle commun restent propres à l’écran.
- Délais réalistes et annulables (`SimulateScreenLatencyAsync("fiche/…")`) : aperçu 20–60 ms, lecture 140–320 ms,
  groupes 120–300 ms, verrouillages 450–1 100 ms, connexions par contrôleur 600–1 400 ms, ping 250–900 ms, sessions
  400–1 000 ms, inventaire 900–2 000 ms, stratégie 200–500 ms, sécurité 250–700 ms, métadonnées 150–400 ms.
- À la lecture par contrôleur, chaque contrôleur autre que le premier a 12 % de chances de ne pas répondre (« Non joint », délai de 8 s dépassé), comme sur un vrai domaine.
- Le journal 4740 d’un compte est un historique fixe sur 720 h (le même à chaque lecture, filtré par la fenêtre) ; environ la
  moitié des verrouillages sont précédés d’un refus fictif de la protection des comptes de Domenia (4 à 110 s avant).
- Les membres d’un groupe se lisent par plages de 1 500 (un délai par plage) ; la réponse transitive suit les `memberOf` de
  l’annuaire fictif, sans le groupe principal comme le contrôleur.
- Une suppression retire les associations locales de l’objet (comptes ↔ postes) de la mémoire de la session.

## 5. Mode annuaire

Lectures faites par `Domenia.Ad` (non branché dans cette version), toujours hors du fil de l’interface, annulables.
Les budgets ci-dessous sont des plafonds : une lecture tronquée le dit (`complete = false`, note).

### 5.1 LDAP

| Lecture | Requête | Attributs | Budget |
|---|---|---|---|
| `fiche.read` | Base sur le DN (`(objectClass=*)`), contrôleur lié à la session | `objectClass`, `objectGUID`, `objectSid`, `distinguishedName`, `name`, `cn`, `displayName`, `givenName`, `sn`, `sAMAccountName`, `userPrincipalName`, `mail`, `telephoneNumber`, `mobile`, `ipPhone`, `homePhone`, `facsimileTelephoneNumber`, `wWWHomePage`, `physicalDeliveryOfficeName`, `streetAddress`, `l`, `st`, `postalCode`, `c`, `co`, `title`, `department`, `company`, `employeeID`, `description`, `info`, `manager`, `managedBy`, `memberOf`, `member;range=0-1999`, `primaryGroupID`, `userAccountControl`, `msDS-User-Account-Control-Computed`, `lockoutTime`, `badPwdCount`, `badPasswordTime`, `pwdLastSet`, `msDS-UserPasswordExpiryTimeComputed`, `accountExpires`, `lastLogonTimestamp`, `logonCount`, `logonHours`, `userWorkstations`, `profilePath`, `scriptPath`, `homeDirectory`, `homeDrive`, `adminCount`, `isCriticalSystemObject`, `groupType`, `gPLink`, `dNSHostName`, `operatingSystem`, `operatingSystemVersion`, `servicePrincipalName`, `ms-Mcs-AdmPwdExpirationTime`, `msLAPS-PasswordExpirationTime`, `whenCreated`, `whenChanged`, `uSNChanged` | 1 requête, 10 s |
| `fiche.attributes` | Base sur le DN, `*` puis attributs construits demandés | tous sauf la liste sensible (filtrée côté moteur) | 1 requête, 10 s |
| `fiche.groups` | Base sur chaque DN de `memberOf` par paquets de 40 (`(|(distinguishedName=…)…)`) | `name`, `sAMAccountName`, `groupType`, `objectSid`, `adminCount`, `description` | 2 000 groupes |
| `fiche.groups.nested` | `memberOf` des groupes atteints, en largeur, paquets de 40 DN | `memberOf`, `name`, `groupType`, `objectSid`, `adminCount` | 2 000 groupes, 16 niveaux, 10 s |
| `fiche.groups.why` | Directe : `member` du groupe ; sinon chemin dans le graphe ; sans chemin, réponse du contrôleur par `(memberOf:1.2.840.113556.1.4.1941:=<groupe>)` en base sur l’objet (`TransitiveMemberAsync`) | `distinguishedName` | 5 000 nœuds, 1 requête de plus |
| `fiche.destinations` | Un niveau (`SearchScope.OneLevel`) sous la branche, `(|(objectClass=organizationalUnit)(objectClass=container))`, `CN=Builtin` exclu | `name`, `objectClass`, `distinguishedName` | 2 000 |
| `fiche.groups.delta.check` | Relecture de base de l’objet sur le contrôleur lié | `memberOf` | 1 requête |
| `fiche.members` | Groupe : `member;range=…` par plages de 1 500 ; OU : un niveau (`SearchScope.OneLevel`), `(objectClass=*)` | `objectClass`, `name`, `sAMAccountName`, `userAccountControl`, `distinguishedName` | 2 000 affichés, 50 000 comptés |
| `fiche.relations` | Base locale seulement (relations dérivées des relevés), aucun LDAP | — | — |
| `fiche.history` | `msDS-ReplAttributeMetaData` en base sur l’objet | métadonnées (attribut, date, contrôleur d’origine, version) | 1 requête |
| `fiche.rights` | `nTSecurityDescriptor` (contrôle `SD_FLAGS` = propriétaire + DACL) en base sur l’objet ; `tokenGroups` en base sur le compte de session | — | 2 requêtes |
| `fiche.logonByDc` | Base sur l’objet, sur chaque contrôleur (RWDC et RODC) ; `msDS-LogonTimeSyncInterval` sur la tête du domaine | `lastLogon`, `logonCount` | 1 requête par contrôleur, 8 s chacune, 8 en parallèle au plus |
| `fiche.lockouts` | Émulateur PDC résolu par `fSMORoleOwner` de la tête du domaine (sinon le contrôleur lié, ce qui est dit) | `fSMORoleOwner` | 1 requête |
| `fiche.callSheet.read policy` | `msDS-ResultantPSO` de l’objet, puis la PSO ; stratégie du domaine en repli | `msDS-ResultantPSO`, `msDS-MaximumPasswordAge`, `msDS-LockoutThreshold`… | 2 requêtes |
| Plans | Relecture de base de l’objet (et du groupe, de la cible, du parent) juste avant le plan, puis avant l’envoi | attributs de l’écriture, `uSNChanged` | 1 à 3 requêtes |

### 5.2 Journaux, WMI et sessions

| Lecture | Moyen | Budget |
|---|---|---|
| `fiche.lockouts` | Journal Sécurité de l’émulateur PDC, requête XPath sur l’événement 4740 et le seul SID du compte (`wevtapi.dll`, sans dépendance supplémentaire), fenêtre de 1 à 720 h | 200 événements, 15 s |
| `fiche.presence` | Un `Ping` ICMP vers le `dNSHostName` du poste (ou du poste associé) | 1 essai, 1,5 s |
| `fiche.callSheet.read sessions` | Sessions du poste : WTS (`WTSEnumerateSessions`) puis `Win32_LogonSession` en repli | 5 s |
| `fiche.callSheet.read triage` | CIM sur le poste (DCOM puis WSMan selon la configuration) : `Win32_OperatingSystem` (mémoire, démarrage), `Win32_LogicalDisk` (`DriveType = 3`), `Win32_PerfFormattedData_PerfProc_Process` (5 processus les plus lourds) | 10 s, aucune connexion sans geste |

Aucun relevé ne porte sur tout le domaine : chaque lecture vise l’objet ouvert ou son poste associé.

## 6. Écran

- `web/js/pages/fiche.js` et `web/js/pages/fiche/*.js` ; styles `web/css/pages/fiche.css` (règles sous `[data-page="fiche"]`).
- Paramètres de route : `dn` (objet), `q` (texte résolu par `fiche.resolve` puis remplacé par `dn`), `tab` (onglet),
  `open` (panneau à ouvrir : `edit`, `move`, `groupAdd`, `memberAdd`, `createOu`, `compare`, `lockouts`, `logonByDc`,
  `rights`, `presence`, `nested`, `why`, `raw`, `reset`, `options`, `expiration`, `triage`, `support`), `run` (`1` : lecture
  de l’état de route en simulation seulement, § 1), `other` (compte comparé), `guid` (contrôle d’identité).
- Composants locaux (demandes au kit) : sélecteur d’objets, sélecteur de destination (OU et conteneurs), tableau de faits,
  carte des relations, tuiles de chiffres, tableau de la fiche d’appel, pastille de fraîcheur d’un bloc.
- Partagé (petits ajouts, à revoir à l’intégration) : garde de sortie du routeur `ctx.guardLeave(fn)` (saisies non
  enregistrées, FIC-007, indispensable), marques écriture et réseau des entrées de menu (`kind`, `kit/menu.js` et
  `kit.css`), branchement de l’aperçu navigateur `web/js/mock-fiche.js` dans `mock.js` (2 lignes), surcouche de simulation
  `SimulatedDirectoryOverlay.cs` (à fusionner avec l’écran Poste). Les commandes de palette passent par l’API de l’écran
  shell `ctx.commands.set(list)` (docs/SHELL.md) : `app.js` n’est plus modifié par la fiche. Les icônes `phone`, `mail`
  et `building` sont dessinées dans la page (`ficon()`, `fiche/common.js`) : `kit/glyphs.js` n’est plus modifié.
- Groupes : les colonnes « Via » et « Niveau » n’apparaissent qu’après la lecture des groupes imbriqués (disposition
  mémorisée à part), pour rester sans défilement horizontal.
- Exemples de la page vide : noms de l’annuaire fictif en simulation seulement ; en mode annuaire, ceux de la session
  (son compte, son OU de travail).
- Fenêtre sécurisée : `src/Domenia.App/Secrets/` (`HostPasswordWindow`, `PasswordWindow`, `SecureEntry`). Fenêtre native
  modale au-dessus de l’application, couleurs du thème de la page ; la capture (surface WebView2 seule) ne la montre pas.

### Socle LDAP préparé le 23/10/2026

Le transport exige des noms d’attributs explicites et exclut les secrets avant connexion. Les lecteurs peuvent demander des tranches sans expansion automatique (`ExpandRanges = false`) : les noms `member;range=…` restent alors visibles pour compter et annoncer les limites. L’expansion automatique est bornée à 50 000 valeurs, vérifie la continuité des tranches et la stabilité GUID/USN sur le même contrôleur, et refuse un résultat incomplet. Chaque recherche a aussi un budget total (3 min par défaut, configurable jusqu’à 10 min) en plus du délai par page. Le contrôle `ReadOwnerAndDacl` limite le descripteur aux droits et au propriétaire, sans SACL.

La matérialisation utilise les valeurs de `SearchResultAttributeCollection` : son énumérateur direct est celui de `DictionaryBase`, pas une suite d’attributs ([contrat .NET](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.protocols.searchresultattributecollection)). Ce correctif est compilé ; la recette AD reste à faire.

### Lecteur annuaire raccordé le 23/10/2026

`AdFicheReader` est découvert en mode annuaire. L’ouverture stocke la fiche brute contrôlée avant de la publier ;
l’aperçu, l’index, les suggestions, les relations AD déjà connues et les observations du poste restent locaux.
Les fiches SQLite gardent leur GUID, leur DN, leur date et des empreintes vérifiées. Un ancien DN ne réapparaît pas
lorsqu’un relevé local plus récent a constaté un déplacement. Les résumés de l’index sont datés ; les contacts
sans SID restent utilisables. Une absence de census complet laisse le nombre d’enfants inconnu.

Les enfants directs sont bornés à 2 000 avec sentinelle. Les membres sont comptés par tranches jusqu’à 50 000,
2 000 affichés au plus ; GUID, USN et continuité sont contrôlés. Le graphe reste limité à 2 000 groupes,
16 niveaux et 10 s ; les branches refusées ou étrangères sont inconnues, jamais une preuve de non-appartenance.
Une première tranche ne sert pas à conclure à des groupes retirés depuis la fiche précédente.

Le journal 4740 utilise le lecteur natif partagé de Comptes, avec un budget global de 15 s pour la Fiche et
les vrais refus locaux du garde de comptes. Les lectures de connexion interrogent au plus 50 contrôleurs,
8 en parallèle, 8 s chacun, par GUID et avec le même compte LDAP ; un attribut illisible ne devient pas « jamais
connecté ». La stratégie résultante lit le PSO annoncé, sinon les attributs du domaine, sans valeurs par défaut.
Les métadonnées de réplication sont décodées sans DTD ni résolution externe ; celles des secrets sont exclues.

Les droits restent une estimation : tokenGroups du compte réellement identifié, propriétaire et DACL seulement,
ordre réel des ACE préservé. Une ACE propre à un attribut ne donne pas de droit global ; une condition non
interprétable rend l’estimation inconnue. Le contrôleur décide toujours lors de l’écriture.

Le lecteur WTS ne dispose que d’API de consultation ; il ne ferme ni ne déconnecte aucune session. Tampons et
poignées restent détenus jusqu’au retour natif, même si le budget de 5 s est atteint ; quatre appels natifs
simultanés au plus. Les informations WTS suivent le contrat Windows : **WTSClientProtocolType = 16**,
**WTSSessionInfo = 24** et horloges de `WTSINFOW`. Les anciens champs `WTSIdleTime`/`WTSLogonTime` sont non pris
en charge, contrairement à ce que supposait le lecteur historique D1, conservé intact.
Sources : [énumération WTS_INFO_CLASS](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/ne-wtsapi32-wts_info_class),
[structure WTSINFOW](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/ns-wtsapi32-wtsinfow),
[énumération des sessions](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsenumeratesessionsw).

Le tri CIM est borné à 10 s : système, processeur, disques et deux lectures de `Win32_Process`. Les parts CPU
utilisent le temps réellement écoulé et le nombre de processeurs logiques ; aucune part n’est attribuée à un PID
réutilisé. Le disque système provient de l’OS. Les mesures sont conservées sous GUID après contrôle du nom CIM.
Les associations déclarées/importées de D1, le repli WTS vers CIM, le compte poste secondaire, WSMan et les
indicateurs de registre restent à raccorder dans leurs lots respectifs. Ils ne sont pas qualifiés par ce lot.

Validation à ce stade : compilation Windows Debug/Release, zéro avertissement. Treize tests supplémentaires
écrits et compilés, **exécution et recette AD/native réservées à la validation finale**. Aucun statut du catalogue
requalifié sur cette seule compilation.

### Transport avec le compte sélectionné (23/10/2026)

Les sessions WTS et le tri CIM emploient désormais la cascade Compte poste commune à Comptes, y compris le compte de connexion explicite. La génération et l’époque sont vérifiées après lecture avant publication ; aucune identité de secours n’est essayée. Les copies sécurisées restent détenues jusqu’au retour natif effectif. Les refus d’authentification remontent à la garde commune. Le repli WTS/CIM et WSMan restent à développer ; la compilation ne constitue pas une recette native.

### Repli des sessions vers CIM (23/10/2026)

Le geste Sessions accorde 3 s à WTS puis, si WTS n’a pas pu répondre, le reliquat d’un budget total de 5 s à CIM. Le compte et la copie sécurisée sont conservés : le repli ne consomme pas un second usage du bail. Aucune tentative CIM après rejet des identifiants, ni après une liste WTS vide ou partielle. Un travail natif qui tarde garde ses ressources jusqu’au retour réel ; la session de bureau reste ouverte.

CIM vérifie `Win32_ComputerSystem.Name`, puis lit au plus 64 ouvertures de session de types 2/10/11/12 et 2 000 associations. Les références sont analysées comme données, jamais suivies ; poste/namespace/classe/clés/échappements sont contrôlés, un FQDN étranger n’est pas ramené à un homonyme court. Une association absente ou ambiguë ne produit pas d’identité inventée. Le LUID porte le préfixe `CIM:` et ne sert jamais d’identifiant de session WTS. CIM ne mesure ni état actif/déconnecté, ni protocole effectif, ni inactivité : ces limites sont affichées. Le lecteur d’inventaire utilise la même projection.

Contrats consultés : [Win32_LoggedOnUser](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-loggedonuser) et [Win32_LogonSession](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-logonsession). Quatre tests contrôlés couvrent références étrangères/malformées, association exacte, ambiguïtés et refus de repli ; ils sont compilés, pas encore exécutés. WSMan et la recette des transports réels restent à faire.
