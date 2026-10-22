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
  « Aperçu ») puis `fiche.read` qui le remplace. Le GUID de l’aperçu, ou celui de la route (`guid`), doit être celui
  de la lecture (FIC-033), sinon la page le dit.
- **Rafraîchissement partiel (FIC-031).** `signature` résume identité, états, appartenances et liens : à signature égale,
  la page ne repeint que les champs d’affichage.
- **Invalidation ciblée (FIC-037).** Le moteur garde par session la dernière lecture de chaque objet ; quand une lecture
  montre un autre `uSNChanged` ou un autre DN, seules les lectures rangées sous ce GUID sont oubliées.
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
| `fiche.lockouts` | Journal Sécurité de l’émulateur PDC, requête XPath sur l’événement 4740 et le seul SID du compte (`EventLogQuery`), fenêtre de 1 à 720 h | 200 événements, 15 s |
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
- Partagé (petits ajouts) : garde de sortie du routeur `ctx.guardLeave(fn)` (saisies non enregistrées, FIC-007),
  commandes de palette de l’écran affiché `ctx.commands(list)` (FIC-040), marques écriture et réseau des entrées de menu
  (`kind`), glyphes `phone`, `mail`, `building`, aperçu navigateur `web/js/mock-fiche.js`.
- Fenêtre sécurisée : `src/Domenia.App/Secrets/` (`HostPasswordWindow`, `PasswordWindow`, `SecureEntry`). Fenêtre native
  modale au-dessus de l’application, couleurs du thème de la page ; la capture (surface WebView2 seule) ne la montre pas.
