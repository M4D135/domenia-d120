# Domenia 2 — mode simulation

Demande de David (21 octobre 2026) : pouvoir faire tourner Domenia « en simu sans besoin AD », directement sur
n’importe quel PC Windows, sans la VM du labo. Ce document est la conception du mode simulation ; le contrat des
opérations qu’il sert est dans [`OPERATIONS.md`](OPERATIONS.md). Réalisé le 21 octobre 2026 (état et écarts : § 11).

## 1. Garanties

En simulation, Domenia :

1. **n’accède à rien sur le réseau** : ni LDAP, ni WMI/CIM, ni DNS, ni ping, ni SMB, ni HTTP. Les assemblages
   `System.DirectoryServices*`, `System.Management` et les API réseau ne sont jamais appelés (le projet
   `Domenia.Simulation` ne les référence pas, un test le vérifie). Côté page, l’hôte refuse (403) toute requête de
   WebView2 vers un autre hôte que `domenia.local` (pages, cadres, workers), bloque les navigations de cadres hors de ce
   nom et désactive la vérification de réputation SmartScreen ; à confirmer par une capture réseau dans la VM au moment
   des tests ;
2. **n’écrit rien hors de son dossier de données** (`%LOCALAPPDATA%\Domenia`) : seuls le profil WebView2, le journal
   technique et les préférences locales y vont, comme en mode annuaire. Le profil WebView2 de la simulation est distinct
   (`WebView2-Simulation`) et ses préférences aussi (`preferences-simulation.json`, opérations `LocalWrite` :
   widgets désactivés, OU de travail) : stockage web, cache et préférences ne sont jamais partagés avec le mode annuaire.
   Si Windows ne fournit aucun dossier `%LOCALAPPDATA%` absolu, rien n’est écrit (ni journal, ni profil, ni
   préférences, gardées en mémoire pour la session) et la fenêtre l’explique ;
3. **n’ouvre pas la base locale** de Domenia (SQLite) : aucune donnée fictive n’y entre, aucune donnée réelle n’est
   montrée en simulation ;
4. **est en lecture seule** : toute opération de classe `Write` est refusée par le pont avant son gestionnaire
   (`simulation.readOnly`) ; toute opération `NetworkRead` que l’annuaire fictif ne sert pas (outils distants) est
   refusée par défaut (`simulation.unavailable`) ; seules les écritures `LocalWrite` (préférences de la simulation,
   jamais l’annuaire) sont admises ;
5. **ne demande ni mot de passe ni compte** : aucune saisie d’identifiants, aucun coffre, aucun secret ;
6. **le dit en permanence** : bannière dans la page et titre de fenêtre « Domenia — Simulation » ;
7. **est déterministe** : même graine, même date de référence et même fuseau donnent le même annuaire, à l’octet près ;
8. **ne bloque jamais l’interface** : génération et calculs se font hors du fil de l’interface, comme toute opération
   du pont.

Ces garanties reprennent celles du mode démonstration de Domenia 1 (`Domenia-Demo.Model.ps1`, D002 à D004 : bannière
« DÉMONSTRATION — aucune connexion AD », `DOMENIA_DEMO_WRITE`, `DOMENIA_DEMO_UNAVAILABLE`, aucune saisie de mot de passe),
avec un annuaire de taille réelle au lieu d’une trentaine d’objets.

## 2. Activation

### 2.1 Règle

Le mode est décidé **une fois, au démarrage**, par une fonction pure de `Domenia.Core`
(`ModeResolver.Resolve`), dans cet ordre ; la première règle qui s’applique gagne :

| Ordre | Condition | Mode | `modeReason` |
|---|---|---|---|
| 1 | Argument `--simulation` sur la ligne de commande (casse indifférente, valeur exacte, sans `=`) | simulation | `argument` |
| 2 | `DOMENIA_SIMULATION` vaut `1` (espaces autour tolérés) | simulation | `environment` |
| 3 | `DOMENIA_SIMULATION` vaut `0` | annuaire | `environmentOptOut` |
| 4 | `Domenia.config.json`, à côté de l’exécutable, active `Auth.DemoProvider` (booléen JSON `true`) | simulation | `configuration` |
| 5 | Le poste n’est joint à aucun domaine (groupe de travail ou non joint) | simulation | `notDomainJoined` |
| 6 | L’état de jonction est illisible | simulation | `joinStateUnknown` |
| 7 | Le poste est joint à un domaine | annuaire | `domainJoined` |

- Toute autre valeur de `DOMENIA_SIMULATION` (`true`, `oui`, `2`…) est **ignorée** et tracée une fois dans le journal
  technique (« Valeur de DOMENIA_SIMULATION ignorée : seules 1 et 0 sont admises. »).
- Les autres arguments de la ligne de commande sont ignorés et tracés de même ; aucun n’est recopié dans un message de
  l’interface.
- Règle 4 (décision de David du 21/10, « ok, fais au mieux ») : reprise du réglage `Auth.DemoProvider` de Domenia 1. Le
  fichier garde le format JSON de Domenia 1 (`{ "Auth": { "DemoProvider": true } }`, marque d’ordre des octets admise,
  noms de sections et de clés sans casse comme `ConvertFrom-Json`) ; seul le booléen JSON `true` active la simulation
  (`"true"` ou `1` ne l’activent pas, comme `Test-DomeniaDemoProviderEnabled`). Le fichier n’est lu que si les règles
  1 à 3 ne décident pas, en lecture seule, 1 Mo au plus. Absent : tracé (« Domenia.config.json absent : réglages par
  défaut. »). Invalide (JSON illisible, autre chose qu’un objet, contenu après l’objet, commentaires, virgule finale,
  section ou clé en double à la casse près, plus de 1 Mo, lecture impossible) : tracé avec une raison fixe, jamais son
  contenu ni son chemin, et ignoré ; le démarrage continue avec la règle suivante. `DOMENIA_SIMULATION=0` l’emporte (règle
  3). Les livraisons de Domenia 1 refusaient déjà un fichier livré avec ce réglage (`release_guard.py`).
- Le cas 6 privilégie le démarrage : la simulation est sans risque (lecture seule, données fictives, bannière). Pour
  forcer l’annuaire sur un tel poste : `DOMENIA_SIMULATION=0`.
- Un poste joint mais hors réseau (portable en déplacement) reste en mode annuaire, non connecté : il n’y a pas de
  bascule automatique vers la simulation en cours de session.
- Sur la VM du labo (jointe à `cnamts.local`), la simulation se lance avec `Domenia.exe --simulation`.

Exemples :

```text
Domenia.exe --simulation
set DOMENIA_SIMULATION=1 && Domenia.exe
```

### 2.2 Détection de la jonction, sans réseau

`Domenia.App/Interop/DomainJoin.cs` appelle `NetGetJoinInformation(null, …)` de `netapi32.dll` : avec un serveur nul,
l’API lit l’état local du poste (LSA) et ne contacte aucun contrôleur. Elle renvoie `NetSetupDomainName` (joint,
avec le nom NetBIOS du domaine), `NetSetupWorkgroupName`, `NetSetupUnjoined` ou `NetSetupUnknownStatus`. Le tampon est
libéré par `NetApiBufferFree`. Toute erreur (code de retour non nul) donne l’état « illisible ».

Pour un poste joint, le nom DNS du domaine vient de `DsRoleGetPrimaryDomainInformation(null,
DsRolePrimaryDomainInfoBasic, …)` (`netapi32.dll`) : avec un serveur nul, la fonction lit la LSA locale, sans réseau,
et renvoie `DomainNameDns` et `DomainNameFlat` ; le tampon est libéré par `DsRoleFreeMemory`. Le nom NetBIOS reste le
repli. Le suffixe DNS principal du poste (`GetComputerNameExW(ComputerNameDnsDomain)`) n’est pas utilisé : il peut
différer du domaine AD (espace de noms disjoint).

Sont **exclus** pour cette détection : `Domain.GetComputerDomain()` (contacte un contrôleur), WMI
`Win32_ComputerSystem.PartOfDomain` (WMI), `Environment.UserDomainName` (domaine du compte, pas du poste),
`IPGlobalProperties.DomainName` et `GetComputerNameExW(ComputerNameDnsDomain)` (suffixe DNS, pas la jonction).

Déclaration (`LibraryImport`, d’où `AllowUnsafeBlocks` dans `Domenia.App.csproj`) :

```csharp
[LibraryImport("netapi32.dll", StringMarshalling = StringMarshalling.Utf16)]
[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
internal static partial int NetGetJoinInformation(string? server, out IntPtr nameBuffer, out int status);

[LibraryImport("netapi32.dll")]
[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
internal static partial int NetApiBufferFree(IntPtr buffer);

[LibraryImport("netapi32.dll")]
[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
internal static partial int DsRoleGetPrimaryDomainInformation(IntPtr server, int infoLevel, out IntPtr buffer);

[LibraryImport("netapi32.dll")]
[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
internal static partial void DsRoleFreeMemory(IntPtr buffer);
```

La sonde n’est appelée que si les règles 1 à 3 ne s’appliquent pas (le résolveur reçoit un `Func<DomainJoinInfo>`).

### 2.3 Bannière

- `app.info` renvoie `mode`, `modeLabel`, `modeReason`, `modeDetail` et `banner` (`OPERATIONS.md` § 2). La page
  affiche `banner` dans une bande permanente, non masquable, en haut du shell, et la puce `.live` affiche
  « Annuaire simulé » (`session.info.connection.label`).
- L’hôte met le titre de la fenêtre à « Domenia — Simulation » : la mention reste visible même si la page ne se
  charge pas.
- Texte de la bannière : « Simulation : annuaire fictif example.local, aucune connexion à Active Directory, aucune
  écriture possible. »

## 3. Ce que calcule Domenia 1 (relevé du 21 octobre 2026)

### 3.1 Tableau de bord du parc

Source : `dev/wad/modules/Domenia-BoardFleet.Model.ps1` (règles pures), catalogue des widgets dans
`Domenia-Boards.Model.ps1` (`$script:DomeniaBoardCatalogText.Fleet`), seuils dans `Domenia-HealthRules.Model.ps1`.
Le tableau de bord lit la **base locale** (agrégats SQL du worker `FleetStats`), jamais l’annuaire en direct ; les
relevés de postes (ping, WMI) ne partent que sur geste explicite, bornés à une OU.

| Clé Domenia 1 | Mesure | Données lues |
|---|---|---|
| `fleet.machines`, `fleet.enabled`, `fleet.disabled`, `fleet.accountunknown`, `fleet.accountstatus` | Comptes ordinateur : activés, désactivés, état inconnu | `userAccountControl` |
| `fleet.stale` | Sans connexion AD au-delà du seuil (90 j) | `lastLogonTimestamp` (à 14 jours près) |
| `fleet.lastlogon` | Ancienneté de la dernière connexion : 0–6 j, 7–29 j, 30–89 j, 90–179 j, 180 j et plus, non renseignée | `lastLogonTimestamp` |
| `fleet.created` | Créés ces 30 jours | `whenCreated` |
| `fleet.pwdold` | Mot de passe machine de plus de 60 j | `pwdLastSet` |
| `fleet.servers` | Serveurs / postes | `operatingSystem` + table des versions |
| `fleet.os`, `fleet.versions` | Systèmes et versions de Windows | `operatingSystem`, `operatingSystemVersion` |
| `fleet.eos`, `fleet.win10` | Fin de service (90 jours avant la date), Windows 10 hors LTSC/LTSB/IoT | table `Domenia-WindowsLifecycle.json` |
| `fleet.laps` | Sans LAPS (expiration seulement, jamais le mot de passe) | `ms-Mcs-AdmPwdExpirationTime`, `msLAPS-PasswordExpirationTime` |
| `fleet.bitlocker` | Sans clé BitLocker (sur demande, jamais à la racine du domaine) | objets de récupération BitLocker |
| `fleet.ou` | Postes par OU ou sous-OU | DN parent |
| `fleet.presence` | En ligne / Sans réponse / Non vérifié (ping de moins de 30 jours) | relevé de présence local |
| `fleet.wmi`, `fleet.reach` | Réponse WMI, comparaison ping et WMI | relevés locaux |
| `fleet.users`, `fleet.lastcheck` | Utilisateurs vus en session, date du dernier ping | relevés locaux |
| `fleet.models`, `fleet.releases`, `fleet.ram` | Modèles, versions relevées, mémoire (≤ 4, 5–8, 9–16, 17–32, > 32 Go) | inventaire WMI |
| `fleet.diskfree`, `fleet.lowdisk` | Espace libre sur C: (moins de 10 %, 10–20 %, 20–50 %, 50 % et plus), disque presque plein | inventaire WMI (`DiskSize`, `DiskFree`) |
| `fleet.uptime` | Sans redémarrage depuis 30 j | inventaire WMI (`LastBootUtc`) |
| `fleet.health`, `fleet.attention` | Part des postes sans point, points d’attention du plus grave au moins grave | toutes les règles ci-dessus |
| `fleet.trend*` | Évolution sur 90 jours : postes à traiter, Windows 10, inactifs, disques presque pleins | instantanés quotidiens locaux (`fleet_snapshots.figures`) |

Règles reprises telles quelles : une absence de réponse au ping n’est jamais un verdict d’arrêt (point 72) ; une mesure
inconnue n’est jamais 0 (« taille de disque nulle = inconnue ») ; un relevé de plus de 7 jours est grisé (FI-04) ; au-delà
de 30 jours il est écarté ; le vocabulaire des états de mesure est `Known`, `Absent`, `NotRead`, `Refused`, `Expired`,
`Incomplete`, `Error` (point 3, `Domenia-Collection.Model.ps1`) ; un jour sans instantané est absent de la courbe,
jamais 0.

### 3.2 État des comptes utilisateurs

Source : `Domenia-Directory.Model.ps1` (`Get-DomeniaAccountState`, fiche d’expiration du mot de passe).

- Désactivé : bit 0x2 de `userAccountControl`. N’expire jamais : bit 0x10000. Mot de passe non requis : 0x20. Carte à
  puce exigée : 0x40000.
- Verrouillé : bit 0x10 de `msDS-User-Account-Control-Computed` ; sans ce calcul, un `lockoutTime` non nul donne
  « verrouillage à vérifier », jamais « verrouillé ».
- Mot de passe expiré : bit 0x800000 du même calcul.
- Expiration : `msDS-UserPasswordExpiryTimeComputed` d’abord (`Int64.MaxValue` = n’expire pas) ; `pwdLastSet` = 0 =
  à changer à la prochaine ouverture de session ; sinon estimation par la stratégie (`maxPwdAge`), marquée « estimé ».

Les compteurs de comptes de l’Accueil (actifs, verrouillés, mots de passe expirant) sont **nouveaux** dans Domenia 2 :
Domenia 1 les calcule par compte (fiche, audit), pas en tableau de bord. Ils appliquent ces mêmes règles.

### 3.3 Attributs lus par Domenia 1

| Objet | Attributs | Références |
|---|---|---|
| Utilisateur | `name`, `cn`, `sAMAccountName`, `userPrincipalName`, `displayName`, `givenName`, `sn`, `mail`, `description`, `department`, `title`, `manager`, `employeeID`, `distinguishedName`, `objectGUID`, `objectSid`, `objectClass`, `objectCategory`, `userAccountControl`, `msDS-User-Account-Control-Computed`, `lockoutTime`, `badPwdCount`, `pwdLastSet`, `msDS-UserPasswordExpiryTimeComputed`, `lastLogonTimestamp`, `accountExpires`, `whenCreated`, `whenChanged`, `uSNChanged`, `memberOf`, `primaryGroupID`, `adminCount` | `Domenia-Core.ps1` l. 14666 et 21771, `Domenia-AdAudit.Worker.ps1` l. 516, `Domenia-Reconcile.UI.ps1` l. 10, `Domenia-Demo.Model.ps1` |
| Ordinateur | `name`, `dNSHostName`, `sAMAccountName`, `distinguishedName`, `objectGUID`, `objectSid`, `description`, `location`, `managedBy`, `operatingSystem`, `operatingSystemVersion`, `userAccountControl`, `lastLogonTimestamp`, `pwdLastSet`, `whenCreated`, `whenChanged`, `uSNChanged`, `ms-Mcs-AdmPwdExpirationTime`, `msLAPS-PasswordExpirationTime`, `memberOf`, `primaryGroupID` | `Domenia-DirectorySync.Worker.ps1` l. 86, `Domenia-Relations.UI.ps1` l. 1896, `Domenia-Core.ps1` l. 5701 |
| Groupe | `name`, `sAMAccountName`, `distinguishedName`, `objectGUID`, `objectSid`, `groupType`, `member`, `memberOf`, `adminCount`, `description`, `managedBy`, `mail` | `Domenia-Membership.Worker.ps1` l. 93, `Domenia-Core.ps1` l. 11381, `Domenia-Cache.Model.ps1` l. 15 |
| OU | `name`, `ou`, `distinguishedName`, `objectGUID`, `objectClass`, `description`, `managedBy`, `whenCreated`, `whenChanged`, `uSNChanged` | `Domenia-Core.ps1` l. 7878, `Domenia-Demo.Model.ps1` |
| Relevés de poste (hors AD) | présence (`Presence`, `PresenceCheckedUtc`), utilisateur en session, inventaire WMI (`Model`, `RamBytes`, `DiskSize`, `DiskFree`, `Build`, `OsCaption`, `LastBootUtc`), états de mesure par sonde | `Domenia-BoardFleet.Model.ps1` l. 283–340 et 515–600 |

L’instantané d’annuaire de Domenia 2 (§ 6.2) porte exactement ces attributs, avec leurs codages AD (drapeaux entiers,
dates FILETIME), pour que les mêmes règles servent la simulation et le vrai annuaire.

## 4. L’annuaire fictif

### 4.1 Déterminisme

- **Générateur pseudo-aléatoire maison** `SeededRandom` (SplitMix64), dont la suite est fixée par ce document et ne
  dépend d’aucune version de .NET (`System.Random` est exclu). Tirage d’entier sans biais par rejet ; mélange de
  Fisher-Yates.
- **Sous-suites nommées** : `random.Fork("users")`, `Fork("computers")`, `Fork("presence/3")`… dérivent une graine de
  la graine principale et du hachage FNV-1a 64 du nom. Ajouter un poste ne déplace donc pas les utilisateurs.
- **Graine par défaut** : `20261021`.
- **Date de référence** : `TimeProvider.GetUtcNow()` lue **une seule fois** à la première utilisation de la source,
  tronquée à la minute ; fuseau : `TimeProvider.LocalTimeZone`. Toutes les dates de l’annuaire en dérivent par des
  écarts relatifs. Les tests injectent un `FixedTimeProvider`.
- **Les chiffres du jour ne dépendent que de la graine et du jour de la semaine de la référence** (profil « jour
  ouvré » ou « week-end », § 5.1) : les écarts sont construits loin des seuils (aucun mot de passe n’expire à moins
  d’une heure d’un seuil, aucun disque n’est à moins de 0,1 point d’un seuil).
- **Effectifs exacts** : chaque population à effectif fixé (verrouillés, expirants, disques…) est choisie par mélange
  déterministe parmi les candidats, jamais par tirage indépendant.
- Empreinte de contrôle : SHA-256 du JSON canonique de l’instantané (ordre de déclaration des propriétés, tableaux dans
  l’ordre de génération).

### 4.2 Domaine et stratégie

| Élément | Valeur |
|---|---|
| Domaine DNS / NetBIOS | `example.local` / `EXAMPLE` |
| Racine | `DC=example,DC=local` |
| SID du domaine | `S-1-5-21-a-b-c`, trois entiers tirés de la sous-suite `domain` |
| Contrôleurs | `DC01.example.local` (site Paris, contrôleur de la session), `DC02.example.local` (site Lyon), Windows Server 2022 Datacenter, `OU=Domain Controllers` |
| Stratégie de mot de passe | `maxPwdAge` 90 jours, longueur minimale 12, historique 24, verrouillage après 5 essais, durée et fenêtre d’observation 30 minutes |
| Compte de la session | `EXAMPLE\j.martin`, Julien Martin, `CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,DC=example,DC=local`, membre de `GG-Support-N2` |
| OU de travail | `OU=Postes,DC=example,DC=local`, sous-arborescence |
| Base locale fictive | lue à référence − 12 minutes, complète |

### 4.3 Arborescence des OU (39 OU)

```text
DC=example,DC=local
├── OU=Domain Controllers                 DC01, DC02
├── OU=Utilisateurs
│   ├── OU=Paris        Direction, Finances, Ressources humaines, Informatique, Juridique, Communication, Achats, Commercial
│   ├── OU=Lyon         Commercial, Logistique
│   ├── OU=Marseille    Commercial, Logistique
│   ├── OU=Lille        Commercial
│   ├── OU=Bordeaux     Commercial
│   └── OU=Départs      comptes désactivés en attente de suppression
├── OU=Postes
│   ├── OU=Paris, OU=Lyon, OU=Marseille, OU=Lille, OU=Bordeaux
│   └── OU=Quarantaine  comptes ordinateur désactivés
├── OU=Serveurs         OU=Applications, OU=Fichiers, OU=Impression
├── OU=Groupes          OU=Sécurité, OU=Distribution, OU=Ressources
├── OU=Comptes de service
└── OU=Comptes à privilèges
CN=Users, CN=Computers, CN=Builtin        conteneurs par défaut (non comptés comme OU)
```

Compte : 7 OU à la racine, 6 sous Utilisateurs, 14 OU de service, 6 sous Postes, 3 sous Serveurs, 3 sous Groupes.
Chaque OU a une description en français. Les noms accentués (« Ressources humaines », « Départs », « Sécurité »,
« Comptes à privilèges ») et les espaces exercent l’échappement des DN.

### 4.4 Utilisateurs (1 258 objets, 1 186 actifs)

| Population | Effectif | Actifs | OU |
|---|---|---|---|
| Personnes | 1 236 | 1 166 | `OU=Utilisateurs` |
| Comptes d’administration `adm-…` | 6 | 6 | `OU=Comptes à privilèges` |
| Comptes de service `svc-…` | 13 | 13 | `OU=Comptes de service` |
| Administrateur (RID 500), Invité (501), krbtgt (502) | 3 | 1 | `CN=Users` |

Personnes par OU : Paris 560 (Direction 18, Finances 92, Ressources humaines 64, Informatique 71, Juridique 33,
Communication 41, Achats 52, Commercial 189), Lyon 230 (Commercial 141, Logistique 89), Marseille 190 (Commercial 102,
Logistique 88), Lille 130, Bordeaux 78, Départs 48. Désactivées : les 48 de `OU=Départs` (description « Départ le
jj/mm/aaaa ») et 22 réparties dans les services (« Congé de longue durée »).

Noms :

- `FrenchNames` : au moins 80 prénoms féminins et 80 masculins, dont des composés (Jean-Pierre, Marie-Claire,
  Anne-Sophie), et 200 noms de famille parmi les plus fréquents en France, accents compris (Lefèvre, André, François,
  Guérin, Rivière, Gérard, Benoît, Prévost, Hervé, Léger, Rémy, Lévêque, Maréchal, Barthélemy, Ménard, Carré), avec
  particules et apostrophes (Le Gall, Le Goff, Da Silva, D'Almeida, N'Diaye) ;
- `displayName` et `cn` = « Prénom Nom » ; trois comptes « importés » ont un `cn` « Nom, Prénom » (`CN=Le Gall\, Anne`)
  pour exercer l’échappement RFC 4514 ; deux homonymes dans une même OU reçoivent `cn` « Prénom Nom 2 », le nom affiché
  restant identique ;
- `sAMAccountName` = initiales du prénom (une par partie : Jean-Pierre → `jp`), un point, nom sans accents, espaces,
  apostrophes ni tirets, en minuscules ; 20 caractères au plus ; doublons suffixés `2`, `3`… (`j.martin`, `j.martin2`) ;
  le compte de session est créé en premier et garde `j.martin` ;
- `userPrincipalName` = `sAMAccountName@example.local` ; `mail` = `prenom.nom@example.local` (sans accents) ;
- `title` selon le service, accordé au genre du prénom (Comptable, Contrôleuse de gestion, Chargée de recrutement,
  Gestionnaire de paie, Technicien support, Administratrice systèmes, Juriste, Chargé de communication, Acheteuse,
  Chargée de clientèle, Responsable d’agence, Préparateur de commandes, Responsable d’entrepôt…) ; `department` = nom
  du service ; `physicalDeliveryOfficeName` = site ; `company` = « Example » ;
- `telephoneNumber` dans les plages réservées à la fiction par l’ARCEP (`+33 1 99 00 xx xx` Paris, `+33 4 65 71 xx xx`
  Lyon et Marseille, `+33 3 53 01 xx xx` Lille, `+33 5 36 49 xx xx` Bordeaux) ;
- `manager` : le premier compte créé de chaque OU de service est son responsable ; les responsables ont pour
  `manager` la direction générale (Paris, Direction) ;
- `employeeID` : six chiffres, unique ;
- comptes fixes en plus de Julien Martin : Camille Bernard (Commercial, Lyon, verrouillée) ; `adm-j.martin` et cinq
  autres `adm-…` ; les 13 comptes de service (`svc-sauvegarde`, `svc-impression`, `svc-sql`, `svc-web`,
  `svc-messagerie`, `svc-scan`, `svc-supervision`, `svc-antivirus`, `svc-deploiement`, `svc-annuaire`, `svc-gestion`,
  `svc-paie`, `svc-finance`).

États des 1 186 comptes actifs (effectifs exacts) :

| État | Effectif | Construction |
|---|---|---|
| Verrouillés | 7 | `lockoutTime` = référence − 2 à 28 min, bit 0x10 du calcul, `badPwdCount` = 5 |
| Verrouillage expiré | 2 | `lockoutTime` = référence − 2 à 5 h, bit 0x10 absent (vérifie la règle « `lockoutTime` ne prouve rien ») |
| Mot de passe n’expirant jamais | 16 | les 13 `svc-…`, Administrateur et 2 personnes : `userAccountControl` = 66048, expiration calculée `Int64.MaxValue` |
| À changer à la prochaine connexion | 4 | `pwdLastSet` = 0, expiration calculée 0, jamais connectés |
| Expirés | 11 | `pwdLastSet` = référence − 91 à 130 jours, bit 0x800000 |
| Expirant sous 7 jours | 23 | expiration = référence + 1 h à 6 j 20 h |
| Autres | 1 132 | expiration ≥ référence + 8 jours |

Autres attributs : `badPwdCount` de 1 à 4 sur 30 comptes ; `lastLogonTimestamp` de 0 à 14 jours pour la plupart,
plus de 90 jours pour 40 comptes actifs, absent pour 9 (dont les 4 « à changer ») ; `accountExpires` jamais
(`Int64.MaxValue`) sauf 6 stagiaires (référence + 10 à 70 jours) ; `whenCreated` réparti sur 8 ans, 9 comptes créés
ces 30 derniers jours ; `adminCount` = 1 pour Administrateur, krbtgt et les `adm-…` ; `primaryGroupID` = 513.

### 4.5 Ordinateurs (454 objets)

| Population | Effectif | Emplacement | Nommage |
|---|---|---|---|
| Postes actifs | 412 | `OU=Postes`, par site : Paris 186, Lyon 82, Marseille 64, Lille 44, Bordeaux 36 | `PC-PAR-0001` (fixe), `PT-PAR-0001` (portable, 30 %) ; `PAR`, `LYO`, `MRS`, `LIL`, `BDX` |
| Postes désactivés | 19 | `OU=Quarantaine` | numérotation à la suite |
| Postes juste joints | 3 | `CN=Computers` (hors périmètre) | `DESKTOP-` + 7 caractères tirés |
| Serveurs | 18 | `OU=Serveurs` | `SRV-APP-01…06`, `SRV-SQL-01…03`, `SRV-WEB-01…03` (Applications), `SRV-FIC-01…04` (Fichiers), `SRV-IMP-01…02` (Impression) |
| Contrôleurs | 2 | `OU=Domain Controllers` | `DC01`, `DC02` |

Systèmes des 412 postes actifs (`operatingSystem`, `operatingSystemVersion`) :

| Système | Version | Postes |
|---|---|---|
| Windows 11 Entreprise | `10.0 (26100)` (24H2) | 214 |
| Windows 11 Entreprise | `10.0 (22631)` (23H2) | 96 |
| Windows 11 Entreprise | `10.0 (26200)` (25H2) | 58 |
| Windows 10 Entreprise | `10.0 (19045)` (22H2) | 23 |
| Windows 10 Entreprise LTSC | `10.0 (19044)` (LTSC 2021) | 12 |
| Windows 11 Professionnel | `10.0 (26100)` (24H2) | 9 |

Serveurs : Windows Server 2022 Standard ou Datacenter (`20348`) 10, Windows Server 2025 Standard (`26100`) 4,
Windows Server 2019 Standard (`17763`) 4 ; contrôleurs en 2022 Datacenter.

Attributs : `dNSHostName` = nom en minuscules + `.example.local` ; `userAccountControl` 4096 (actif), 4098 (désactivé),
532480 (contrôleur) ; `primaryGroupID` 515 (516 pour les contrôleurs) ; `description` « Poste de *Prénom Nom* » pour
40 % des postes fixes avec `managedBy` correspondant ; `location` « *Site* – bâtiment *A à C*, étage *0 à 4* ».

États des 412 postes actifs (ensembles disjoints, sauf mention) :

| État | Effectif | Construction |
|---|---|---|
| Sans connexion AD depuis plus de 90 jours | 11 | `lastLogonTimestamp` = référence − 91 à 400 jours ; aussi « mot de passe machine ancien » |
| Jamais connectés | 2 | `lastLogonTimestamp` absent, créés il y a plus de 60 jours ; aussi « mot de passe machine ancien » |
| Mot de passe machine ancien seul | 3 | `pwdLastSet` = référence − 61 à 120 jours |
| Autres | 396 | `lastLogonTimestamp` 0 à 14 jours, `pwdLastSet` 0 à 29 jours |
| Créés ces 30 jours | 4 | dans le périmètre (et les 3 `DESKTOP-` hors périmètre) |
| LAPS Windows | 389 | `msLAPS-PasswordExpirationTime` : 8 expirées, les autres référence + 1 à 30 jours ; 23 sans expiration visible |

Aucun mot de passe LAPS ni clé BitLocker n’existe dans la simulation : seules des dates d’expiration.

### 4.6 Groupes (75)

| Groupes | Nombre | Emplacement | Type |
|---|---|---|---|
| Builtin : Administrateurs, Utilisateurs, Invités, Opérateurs de compte, Opérateurs de serveur, Opérateurs d’impression, Opérateurs de sauvegarde, Utilisateurs du Bureau à distance | 8 | `CN=Builtin` | local intégré, SID `S-1-5-32-…` |
| Admins du domaine (512), Utilisateurs du domaine (513), Invités du domaine (514), Ordinateurs du domaine (515), Contrôleurs de domaine (516), Administrateurs du schéma (518), Administrateurs de l’entreprise (519), Propriétaires créateurs de la stratégie de groupe (520), Protected Users (525) | 9 | `CN=Users` | global ou universel de sécurité |
| `GG-<Service>-<Site>` (Direction, Finances, RH, Informatique, Juridique, Communication, Achats, Commercial à Paris ; Commercial et Logistique à Lyon et Marseille ; Commercial à Lille et Bordeaux) | 14 | `OU=Sécurité` | global de sécurité |
| `GG-Admins-Postes`, `GG-Admins-Serveurs`, `GG-Support-N1`, `GG-Support-N2` | 4 | `OU=Sécurité` | global de sécurité |
| `GG-App-Paie`, `-Compta`, `-CRM`, `-GED`, `-Planning`, `-Stocks`, `-Achats`, `-Intranet`, `-VPN`, `-Messagerie` | 10 | `OU=Sécurité` | global de sécurité |
| `DL-Partage-<X>-L` et `-M` pour Direction, Finances, RH, Informatique, Juridique, Communication, Achats, Commercial, Logistique, Qualité, Projets, Commun | 24 | `OU=Ressources` | local de domaine de sécurité |
| `LD-Paris`, `LD-Lyon`, `LD-Marseille`, `LD-Lille`, `LD-Bordeaux`, `LD-Tous` | 6 | `OU=Distribution` | distribution |

Appartenances (modèle AGDLP) : chaque personne active est dans le `GG` de son service et de son site et dans le `LD`
de son site, plus 0 à 3 groupes d’application selon le service ; les `GG` de service sont dans les `DL-Partage` de
leur service (`-M`) et dans `DL-Partage-Commun-M` ; `LD-Tous` contient les `LD` de site ; `GG-Support-N2` (6 comptes,
dont Julien Martin) est dans `GG-Admins-Postes` ; les `adm-…` sont dans `GG-Admins-*` et `Protected Users`, deux d’entre
eux dans Admins du domaine avec Administrateur. Les groupes principaux (513, 515, 516) passent par `primaryGroupID`,
pas par `member`, comme dans AD. `member` et `memberOf` sont symétriques, sans cycle, profondeur au plus 2. Les comptes
de `OU=Départs` n’ont plus que leur groupe principal.

**Total** : 39 OU + 1 258 utilisateurs + 454 ordinateurs + 75 groupes = **1 826 objets** (`store.objects`).

## 5. Relevés fictifs des postes

### 5.1 État initial (manche 0)

Profil choisi par le jour de la semaine **local** de la référence :

| Mesure (412 postes actifs de l’OU) | Jour ouvré | Samedi, dimanche |
|---|---|---|
| En ligne (réponse de moins de 30 jours) | 287 | 61 |
| Sans réponse (relevé de moins de 30 jours) | 98 | 324 |
| Non vérifié (aucun relevé de moins de 30 jours) | 27 | 27 |

- Les réponses « en ligne » de la manche 0 sont datées entre le début du jour local et la référence (8 heures au plus
  avant) : elles comptent toutes dans l’activité du jour.
- Fraîcheur : 346 relevés de moins de 7 jours, 39 de 7 à 30 jours, 15 de plus de 30 jours, 12 jamais relevés
  (84,0 %). Les 13 postes inactifs dans l’annuaire (§ 4.5) sont parmi les « sans réponse » et « non vérifié ».
- Chaque poste a un rang fixe `r` (mélange de la sous-suite `presence`) ; les postes en ligne de la manche 0 sont
  ceux de plus petit rang parmi les éligibles.
- 3 postes fixes ont une sonde toujours en erreur (état `Error`) : ils sont parmi les « jamais relevés ».
- Un poste dont le ping est filtré répond à WMI sans jamais répondre au ping (`lastSeenAt` nul, inventaire présent) :
  point 72 de Domenia 1.

Inventaire (WMI) : 371 postes relevés depuis moins de 30 jours, 41 sans relevé utilisable. Espace libre sur C: :
9 postes sous 10 % (3,1 ; 4,0 ; 5,2 ; 6,4 ; 7,7 ; 8,3 ; 8,9 ; 9,4 ; 9,8 %), 17 entre 10 et 20 %, 345 à 20 % ou plus.
Disques de 256 Go (60 %), 512 Go (35 %) et 1 To (5 %), tailles réelles légèrement inférieures au nominal. 21 postes
sans redémarrage depuis 31 à 75 jours, les autres de 0 à 12 jours. Mémoire : 8 Go (25 %), 16 Go (60 %), 32 Go (15 %).
Modèles : Dell Latitude 5440, Dell OptiPlex 7010, HP EliteBook 840 G10, HP EliteDesk 800 G6, Lenovo ThinkPad T14 Gen 4,
Lenovo ThinkCentre M70q. Les postes en alerte ou à surveiller (disque, redémarrage) ont tous un inventaire.

Points d’attention : 9 disques critiques, 17 disques serrés, 21 redémarrages anciens, 11 inactifs, 2 jamais connectés,
3 mots de passe machine anciens seuls, soit **63 postes** à surveiller.

### 5.2 Historique quotidien

13 instantanés quotidiens passés (jours J−13 à J−1), plus le jour courant calculé en direct, soit 14 points. Chaque
instantané porte `WorkstationsOnline`, `WorkstationsSeen`, `ActiveAccounts`, `LockedAccounts`, `PasswordsExpiring` et
`DiskAlerts`, tirés de la sous-suite `history` :

- postes en ligne : 265 à 300 en jour ouvré, 48 à 70 le week-end ; postes vus dans la journée : en ligne + 8 à 25
  (jour ouvré) ou + 5 à 12 (week-end) ;
- comptes actifs : suite croissante par petits pas jusqu’à 1 186 (arrivées et départs) ;
- verrouillés 0 à 12, expirants 15 à 26, alertes disque 6 à 11.

Aucun jour ne manque dans la simulation par défaut ; un test retire des jours pour vérifier qu’ils restent absents.

### 5.3 Actualisations (manches suivantes)

L’annuaire fictif **ne change pas** pendant la session : une actualisation de la famille « annuaire » relit les mêmes
valeurs et date la lecture de maintenant. L’inventaire non plus : seules ses dates de relevé passent à maintenant.
Seule la **présence** évolue, par manches déterministes :

- la manche `k` (k ≥ 1) part à chaque actualisation de `workstationsOnline` ou de `measureFreshness` ; tous les postes
  actifs de l’OU **de travail** sont sondés à l’instant de l’actualisation (la manche est tirée sur tout `OU=Postes`,
  puis seuls les postes de l’OU de travail prennent leur nouveau relevé ; les autres gardent le précédent) ;
- les 3 postes en erreur gardent leur relevé précédent (« non vérifié ») ; les 13 postes inactifs ne répondent pas ;
- parmi les autres, exactement `N_k = cible du profil + e_k` répondent, avec `e_k` ∈ [−6 ; +6] tiré de la sous-suite
  `presence/k` ; ce sont les `N_k` postes de plus petit score `r + j(k)`, `j(k)` ∈ [0 ; 40[ tiré par poste : la
  population en ligne varie un peu d’une manche à l’autre sans être redistribuée ;
- l’activité du jour compte les postes distincts ayant répondu aujourd’hui sur toutes les manches (jamais en baisse
  pendant la journée) ;
- deux sources neuves avec la même graine et la même référence donnent la même suite de manches.

### 5.4 Journal fictif

14 entrées datées relativement à la référence, la plus récente d’abord :

| Écart | Libellé | Ton |
|---|---|---|
| −12 min | Lecture de l’annuaire : *nombre d’objets* objets | ok |
| −28 min | Relevé de présence de l’OU Paris : 158 en ligne sur 186 | ok |
| −55 min | Relevé d’inventaire de l’OU Lyon : 74 postes sur 82 | ok |
| −1 h 39 | Diagnostic de verrouillage : Camille Bernard | warn |
| −3 h 21 | Lecture BitLocker refusée pour l’OU Marseille | alert |
| −3 h 46 | Recherche « dupont » : 12 résultats | info |
| −5 h 02 | Relevé de présence de l’OU Lyon : 61 en ligne sur 82 | ok |
| −6 h 30 | Export des comptes verrouillés : 7 lignes | info |
| −1 j 1 h | Lecture de l’annuaire : 1 824 objets | ok |
| −1 j 2 h | Relevé d’inventaire de l’OU Paris : 171 postes sur 186 | ok |
| −1 j 4 h | Relevé de présence de l’OU Marseille : sondes refusées pour 3 postes | warn |
| −2 j | Requête « Postes sans LAPS » : 23 résultats | info |
| −2 j 3 h | Lecture de l’annuaire : 1 821 objets | ok |
| −3 j | Première lecture de l’OU Postes : 431 comptes ordinateur | ok |

Seule la première entrée est calculée (nombre réel d’objets) ; les autres sont décoratives. Les opérations de la
session (actualisations, activations) s’y ajoutent en tête, en mémoire seulement.

## 6. Architecture

### 6.1 Projets

```text
src/Domenia.Core          + Startup/, Directory/, Fleet/, Dashboard/, Text/   (pur, sans E/S)
src/Domenia.Simulation    NOUVEAU, référence Domenia.Core seulement
src/Domenia.Bridge        + BridgeJson, BridgeArguments, Operations/, garde de la simulation
src/Domenia.App           + choix du mode, sonde de jonction, composition, bannière de fenêtre
tests/Domenia.Tests       + référence Domenia.Simulation, nouveaux fichiers de tests
```

Dépendances : `Simulation → Core` ; `Bridge → Core` ; `App → Core, Bridge, Simulation, Store, Ad, Inventory, Engine` ;
`Tests → Core, Bridge, Simulation, Store, Engine`. `Domenia.Simulation` ne référence ni `Domenia.Ad`, ni
`Domenia.Inventory`, ni `Domenia.Store`, ni aucun paquet. `build-vm.ps1` crée `Domenia.sln` s’il manque et y ajoute tout
projet de `src/` ou `tests/` absent (la solution n’est pas versionnée).

`Domenia.Simulation.csproj` :

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><RootNamespace>Domenia.Simulation</RootNamespace></PropertyGroup>
  <ItemGroup><ProjectReference Include="../Domenia.Core/Domenia.Core.csproj" /></ItemGroup>
</Project>
```

### 6.2 Dans `Domenia.Core`

**Choix du mode** (`Startup/`) : `AppMode` (`Simulation`, `Directory` ; texte JSON `"simulation"`, `"annuaire"`),
`ModeReason`, `DomainJoinState` (`Joined`, `Workgroup`, `Unjoined`, `Unknown`), `DomainJoinInfo(State, DomainName)`,
`ModeDecision(Mode, Reason, Detail, Banner, JoinedDomain, Warnings)` et :

```csharp
public static class ModeResolver
{
    public const string SimulationArgument = "--simulation";
    public const string SimulationVariable = "DOMENIA_SIMULATION";

    // Pure: the probe is called only when neither the argument nor the variable decides.
    public static ModeDecision Resolve(IReadOnlyList<string> arguments, string? variableValue, Func<DomainJoinInfo> probeJoin);
}
```

`AppInfo` et `AppInfoBuilder.Build(ModeDecision, string runtime, string webViewRuntime)` produisent le résultat de
`app.info`.

**Source d’annuaire en lecture seule** (`Directory/`) :

```csharp
/// <summary>Read-only access to a directory and to the local observations of its workstations.</summary>
public interface IDirectorySource
{
    DirectorySourceKind Kind { get; }                                  // Simulation or ActiveDirectory

    Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken);   // in-memory state, no I/O

    Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken);     // LocalRead: last known state

    Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken); // NetworkRead in directory mode, bounded to the working OU
}

public enum MeasureFamily { Directory, Presence, Inventory }

public sealed record DirectoryState(DirectorySnapshot Directory, FleetObservations Observations, ImmutableArray<DailyFigures> History);
```

L’interface n’a **aucune** méthode d’écriture : la simulation est en lecture seule par construction. Les échecs
attendus lèvent `DomeniaOperationException(code, message)` (Core), que le pont transmet tels quels.
`RefreshAsync(Presence)` et `RefreshAsync(Inventory)` lèvent `scope.tooWide` si l’OU de travail passée (`scope`, celle
de `session.setScope`, `OPERATIONS.md` § 11) est la racine du domaine ou manque, dans les deux modes.
`DirectoryState.HistoryScope` dit pour quelle OU l’historique quotidien a été relevé : pour une autre OU de travail, le
calcul laisse les jours passés des chiffres de postes absents.

`UnavailableDirectorySource` (Core) sert le mode annuaire tant que `Domenia.Ad` n’existe pas : `GetSessionAsync` renvoie
une session « non connectée » construite à partir des informations locales que lui passe l’application (domaine de
jonction, compte du jeton Windows), les deux autres méthodes lèvent `source.unavailable`.

**Instantané** (records immuables, `ImmutableArray`) aux attributs du § 3.3, codages AD conservés :

```csharp
public sealed record DirectorySnapshot(DomainInfo Domain, DateTimeOffset ReadAt, bool Complete,
    ImmutableArray<DirectoryOu> OrganizationalUnits, ImmutableArray<DirectoryUser> Users,
    ImmutableArray<DirectoryComputer> Computers, ImmutableArray<DirectoryGroup> Groups);

public sealed record DirectoryUser(Guid ObjectGuid, string Sid, string DistinguishedName, string Cn,
    string SamAccountName, string UserPrincipalName, string DisplayName, string? GivenName, string? Surname,
    string? Mail, string? Title, string? Department, string? Office, string? TelephoneNumber, string? ManagerDn,
    string? Description, string? EmployeeId, int UserAccountControl, int? ComputedAccountControl,
    long? LockoutTime, int? BadPasswordCount, long? PasswordLastSet, long? PasswordExpiryComputed,
    long? LastLogonTimestamp, long? AccountExpires, DateTimeOffset WhenCreated, DateTimeOffset WhenChanged,
    long UsnChanged, int? AdminCount, int PrimaryGroupId, ImmutableArray<string> MemberOf);
```

et de même `DirectoryComputer` (`Name`, `DnsHostName`, `OperatingSystem`, `OperatingSystemVersion`, `Location`,
`ManagedByDn`, `UserAccountControl`, `PasswordLastSet`, `LastLogonTimestamp`, `LapsKind`, `LapsExpiration`…),
`DirectoryGroup` (`GroupType`, `Members`, `MemberOf`, `AdminCount`…), `DirectoryOu`, `DomainInfo` (avec
`DomainPasswordPolicy`). Les dates « large integer » restent des `long` FILETIME ; `AdValues` (Core) les convertit
(`0` et `Int64.MaxValue` ont leur sens AD) et `AccountState.Evaluate(uac, computed, lockoutTime)` reprend
`Get-DomeniaAccountState`. `DistinguishedName` (Core) échappe et lit les DN selon la RFC 4514.

**Relevés** (`Fleet/`) : `MeasureState` (`Known`, `Absent`, `NotRead`, `Refused`, `Expired`, `Incomplete`, `Error`),
`PresenceMeasure(State, Answered, CheckedAt, LastOnlineAt)`, `InventoryMeasure(State, CheckedAt, SystemDiskSizeBytes,
SystemDiskFreeBytes, LastBootAt, Model, MemoryBytes, OsCaption, Build)`, `WorkstationObservation(ComputerGuid,
Presence, Inventory)`, `FleetObservations(TakenAt, Workstations, SeenToday)`, `DailyFigures(Day, WorkstationsOnline,
WorkstationsSeen, ActiveAccounts, LockedAccounts, PasswordsExpiring, DiskAlerts)` (champs nullables : un chiffre absent
d’un instantané n’est jamais 0). `WindowsRelease.Describe(operatingSystem, operatingSystemVersion)` donne le libellé
regroupé (« Windows 11 24H2 », « Windows 10 LTSC 2021 », « Windows Server 2022 ») par une petite table de builds ; la
table des fins de service de Domenia 1 sera portée avec `fleet.eos`.

**Mesures du tableau de bord** (`Dashboard/`) — fonction **pure**, réutilisable telle quelle avec le vrai annuaire :

```csharp
public sealed record DashboardInput(DirectoryState State, ScopeSelection Scope, DashboardPolicy Policy,
    IReadOnlySet<string> DisabledWidgets, ImmutableArray<JournalEntry> Journal, DateTimeOffset Now, TimeZoneInfo TimeZone);

public static class DashboardCalculator
{
    public static DashboardSummary Compute(DashboardInput input);
    public static DashboardWidget ComputeWidget(string widgetId, DashboardInput input);
}
```

- aucune horloge, aucun fuseau ni aucune culture lus en interne : `Now` et `TimeZone` sont des entrées ; mêmes
  entrées, même résultat ;
- `DashboardPolicy.Default` porte les seuils de `OPERATIONS.md` § 4.8 ; `WidgetCatalog` la liste fermée (identifiant,
  type, titre, périmètre, famille) ;
- les DTO (`DashboardSummary`, `KpiWidget`, `DistributionWidget`…) sont des records dont les noms donnent le camelCase
  du contrat ; les widgets sont sérialisés par leur type réel ;
- `FrenchText` produit les textes : séparateurs U+202F et U+00A0, virgule décimale, signe moins U+2212, jours abrégés
  figés (`lun.` … `dim.`), sans dépendre de la culture du poste ;
- pourcentages au plus fort reste (somme exacte de 100,0).

**Service** (`Dashboard/DashboardService`) : seul état mutable, en mémoire et sans E/S. Il reçoit `IDirectorySource`,
`OperationJournal` (anneau de 200 entrées, Core) et `TimeProvider`, et offre `GetSessionInfoAsync`, `GetSummaryAsync`,
`RefreshAsync(widgetId)` et `SetEnabled(widgetId, enabled)` selon `OPERATIONS.md` § 3 à 7 : liste des widgets
désactivés échangée atomiquement, dernier état connu conservé pour `setEnabled`, actualisations sérialisées par un
`SemaphoreSlim`, compteur de lectures en cours pour `session.info.tasks`.

### 6.3 Dans `Domenia.Simulation`

| Fichier | Rôle |
|---|---|
| `SimulationOptions.cs` | Graine (`20261021`), latence (`Realistic` ou `None`). |
| `SimulationProfile.cs` | Tous les effectifs et répartitions des § 4 et 5, en constantes nommées. |
| `SeededRandom.cs` | SplitMix64, sous-suites FNV-1a, entier sans biais, mélange. |
| `FrenchNames.cs` | Prénoms (genre), noms, intitulés de poste par service. |
| `SimulatedWorldGenerator.cs` | Fonction pure `(options, référence, fuseau) → SimulatedWorld`. |
| `SimulatedWorld.cs` | Instantané, relevés de la manche 0, historique, journal initial, session. |
| `PresenceRounds.cs` | Manches de présence du § 5.3, pures. |
| `SimulatedDirectorySource.cs` | `IDirectorySource` : monde généré à la première utilisation (`Lazy`, hors du fil de l’interface), manches, dates de relevé, latence ; `ScreenStream(écran)` et `SimulateScreenLatencyAsync` pour les lecteurs d’écran. |
| `Screens/SimulatedDirectoryTreeReader.cs` | `IDirectoryTreeReader` (arborescence des OU) dérivé du monde généré, sans changer le générateur (`PLATFORM.md` § 4). |

Latence simulée : `ReadLocalAsync` 120 à 250 ms (sous-suite `latency/read/n`), `RefreshAsync` 400 à 900 ms pour toutes
les familles, calcul local compris (sous-suite `latency/refresh/n`), par `Task.Delay(durée, timeProvider,
cancellationToken)` (annulable) ; aucune avec `Latency = None`. Les deux compteurs sont séparés : les actualisations,
passées l’une après l’autre par `DashboardService`, gardent la même suite de délais quelles que soient les lectures
concurrentes. `GetSessionAsync` n’attend pas.

### 6.4 Dans `Domenia.Bridge`

- `BridgeJson.Options` : camelCase, énumérations en texte camelCase, convertisseur `DateTimeOffset` → `yyyy-MM-ddTHH:mm:ssZ`
  (UTC), `DateOnly` → `yyyy-MM-dd`, champs nuls **écrits** ; seul `BridgeResponse.Error` est omis quand il est nul
  (`[JsonIgnore(Condition = WhenWritingNull)]`). `MainForm` sérialise avec ces options au lieu des siennes.
- `BridgeArguments` : `RequireNone(args)`, `ReadObject(args, allowedNames)` (objet exigé, propriété inconnue ou en double
  refusée), `GetString`, `GetBoolean` ; échecs `arguments.invalid` avec les précisions de `OPERATIONS.md` § 1.4.
- `Operations/SessionOperations.cs` (`session.info`) et `Operations/DashboardOperations.cs` (`dashboard.*`) :
  `Create(DashboardService)` renvoie les `OperationDefinition` avec les classes du contrat. Les gestionnaires ne font
  que valider les arguments et appeler le service.
- `BridgeDispatcher` : traduit `DomeniaOperationException` comme `BridgeOperationException`, et accepte une garde
  d’admission (`Func<OperationDefinition, BridgeError?>`) évaluée avant le gestionnaire ; la garde de simulation refuse
  la classe `Write` (`simulation.readOnly`) et toute `NetworkRead` non marquée `ServedInSimulation`
  (`simulation.unavailable`). L’événement `Refused(code, opération)` signale chaque refus à l’hôte, qui le trace (code
  et nom d’opération déclaré ou bien formé, jamais le contenu).

### 6.5 Dans `Domenia.App`

1. `Program.Main(string[] args)` : `ModeResolver.Resolve(args, Environment.GetEnvironmentVariable("DOMENIA_SIMULATION"),
   DomainJoin.Read)` ; trace la décision et ses avertissements dans le journal technique.
2. Composition (`Composition.cs`) : simulation → `new SimulatedDirectorySource(SimulationOptions.Default,
   TimeProvider.System)` ; annuaire → `UnavailableDirectorySource` (plus tard `Domenia.Ad`). Puis le contexte de
   services (`EngineContext` : préférences du mode, horloge, journal technique, lecteurs d’écran trouvés pour la source)
   et le registre construit à partir des modules trouvés par réflexion dans les assemblages `Domenia.*` (`HostOperations`
   pour `app.info`, `SessionOperations`, `DashboardOperations`, `DirectoryTreeOperations`…, `PLATFORM.md`). Rien de lourd
   ici : aucune génération, aucune lecture.
3. `MainForm(ModeDecision, OperationRegistry)` : titre « Domenia — Simulation » en simulation, garde d’admission selon
   le mode, sérialisation `BridgeJson.Options`. Les messages restent traités hors du fil de l’interface (`Task.Run`
   existant).
4. `Domenia.App.csproj` : référence `Domenia.Simulation`, `AllowUnsafeBlocks` pour `LibraryImport`.
5. Erreurs : `Application.ThreadException`, `AppDomain.UnhandledException` et `TaskScheduler.UnobservedTaskException`
   écrivent dans le journal technique ; une erreur imprévue de l’interface affiche un message en français puis ferme
   l’application. Un moteur WebView2 introuvable ou un démarrage impossible remplace la page par un message explicite
   (le titre « Domenia — Simulation » reste). Les messages du pont sont traités dans une tâche dont toute exception est
   tracée ; une réponse postée après la fermeture de la fenêtre est abandonnée et tracée.
6. WebView2 : profil par mode (`WebView2` ou `WebView2-Simulation`), requêtes hors `https://domenia.local` refusées
   (403, sauf `data:`, `blob:` et `about:`), navigations de cadres gardées, SmartScreen désactivé, origine d’un message
   refusée tracée (hôte seulement).

## 7. Fil d’exécution et sûreté

- Le fil de l’interface ne fait que recevoir et poster les messages ; génération (≈ 1 800 objets), calculs et attentes
  se font sur le pool de threads.
- Le monde fictif est immuable une fois généré ; l’état qui évolue (manche courante, dates de relevé, préférences,
  journal) est échangé atomiquement ou protégé par verrou.
- Annulation : jeton de vie de la fenêtre ; une attente simulée annulée répond `operation.cancelled`.
- Journal technique : la décision de mode, les valeurs ignorées et les erreurs imprévues ; jamais de données fictives
  en masse, jamais de saisie de la page.

## 8. Tests à écrire (exécutés à la fin, dans la VM)

Projet `tests/Domenia.Tests` (lanceur maison `[Test]` + `Check.*`), avec un `FixedTimeProvider : TimeProvider` (heure et
fuseau fixés) et une référence par défaut `2026-10-21T16:26:00Z`, fuseau de Paris (mercredi).

**`ModeResolverTests.cs`**

1. `--simulation` donne la simulation (`argument`) même avec `DOMENIA_SIMULATION=0` et un poste joint ; la sonde n’est
   pas appelée.
2. `DOMENIA_SIMULATION=1` et ` 1 ` donnent `environment` ; `0` donne l’annuaire même hors domaine ; `true`, `oui`, `2`
   sont ignorés avec un avertissement.
3. Hors domaine → simulation (`notDomainJoined`) ; état illisible → simulation (`joinStateUnknown`) ; joint → annuaire
   (`domainJoined`, nom du domaine dans `modeDetail`).
4. `--SIMULATION` admis ; `--simulation=1` et `-simulation` non reconnus ; arguments inconnus signalés sans être recopiés.
5. `AppInfoBuilder` : `banner` non nul seulement en simulation ; textes de `modeDetail` du contrat.

**`SimulationGeneratorTests.cs`**

6. Même graine, même référence, même fuseau → même empreinte SHA-256 ; autre graine → autre empreinte.
7. Effectifs du profil : 1 258 utilisateurs dont 1 186 actifs, 454 ordinateurs, 431 dans `OU=Postes` dont 412 actifs,
   75 groupes, 39 OU, 1 826 objets.
8. Chiffres du jour identiques pour deux références de jour ouvré de mois différents ; profil week-end un samedi
   (61 en ligne).
9. DN uniques, chaque parent existe, échappement RFC 4514 (`CN=Le Gall\, Anne`), lecture inverse identique.
10. `sAMAccountName` uniques sans casse, 20 caractères au plus, ASCII minuscule ; UPN et `employeeID` uniques ;
    `j.martin` est Julien Martin.
11. GUID et SID uniques ; RID bien connus (500, 501, 502, 512 à 520, 525) ; SID `S-1-5-32-…` pour Builtin.
12. `member` et `memberOf` symétriques, sans cycle, profondeur ≤ 2 ; comptes de `OU=Départs` sans groupe.
13. Noms : accents conservés dans `displayName`, aucun champ obligatoire vide, intitulés accordés.
14. États des comptes cohérents : verrouillé ⇒ actif, bit 0x10 et `lockoutTime` dans les 30 minutes ; expiré ⇔ date
    ≤ référence ou bit 0x800000 ; n’expire jamais ⇒ `Int64.MaxValue` ; aucune expiration à moins d’une heure d’un seuil.
15. États des postes cohérents : inactif ⇒ pas en ligne ; disque ⇒ inventaire connu, libre ≤ taille ; démarrage ≤
    référence ; version cohérente avec le système ; aucun disque à moins de 0,1 point d’un seuil.
16. Répartition des systèmes conforme au § 4.5 ; aucune date future hors expirations (mot de passe, LAPS,
    `accountExpires`).

**`DashboardCalculatorTests.cs`** (petits instantanés écrits à la main)

17. Pureté : deux calculs sur la même entrée donnent le même JSON ; l’entrée n’est pas modifiée.
18. Verrouillage : `lockoutTime` > 0 sans bit 0x10 → non compté ; calcul illisible → `toCheck`.
19. Fenêtre d’expiration : expiration = maintenant → expiré ; maintenant + 7 jours → compté ; + 7 jours + 1 s → non
    compté ; n’expire jamais, désactivé et `pwdLastSet` = 0 exclus.
20. Comptes désactivés non actifs ; ordinateurs exclus des comptes utilisateurs.
21. Présence : réponse de 31 jours → non vérifié ; « sans réponse » reste `info`, jamais `alert`.
22. Seuils disque : 9,9 % critique, 10,0 % serré, 19,9 % serré, 20,0 % sain ; taille 0 → sans relevé.
23. Fraîcheur : ventilation de somme `total`, pourcentage au dixième.
24. Systèmes : éditions regroupées, 4 segments + `autres`, somme des pourcentages = 100,0, égalités par libellé.
25. Activité : toujours 7 points, `null` pour un jour sans instantané, aujourd’hui `partial`.
26. Historique : jours manquants absents, `delta` nul si le point de J−7 manque, libellés `+9`, `−1`, `Stable`.
27. Liste à surveiller : ordre gravité, règle, valeur, nom ; 6 lignes au plus ; `total` = postes distincts.
28. Widget désactivé : `data` nul, `tone` `off`, `measuredAt` nul ; widget jamais mesuré : `data` nul, `enabled` vrai.
29. Mesure de plus de 7 jours : `stale` vrai, `tone` `off`.
30. Périmètre : `CN=Computers` et `OU=Quarantaine` (désactivés) hors des chiffres de l’OU `Postes`.

**`DashboardOperationsTests.cs`** (pont réel, `SimulatedDirectorySource` sans latence)

31. `dashboard.summary` : 10 widgets dans l’ordre du contrat ; 287 / 412, 1 186, 7, 23, 9 ; segments ; 84,0 % ;
    63 postes à surveiller ; `store.objects` = 1 826.
32. Noms de propriétés exacts par type de widget (`JsonDocument`), dates au format `yyyy-MM-ddTHH:mm:ssZ`, champs nuls
    présents.
33. `session.info` : forme exacte, `EXAMPLE\j.martin`, `Julien`, étape `dashboard` faite après un premier résumé.
34. `dashboard.widget.refresh` : `widget.unknown`, `arguments.invalid` (id absent, non texte, propriété en trop,
    `args` non objet).
35. Widget désactivé : `widget.disabled`, aucune manche n’avance.
36. `setEnabled(false)` puis résumé : widget présent sans données ; `setEnabled(true)` le rétablit ; deuxième appel
    identique sans entrée de journal.
37. Suite des manches de présence identique pour deux sources neuves (5 actualisations) ; `measuredAt` = horloge
    injectée.
38. Annulation pendant une latence simulée → `operation.cancelled`.
39. Mode annuaire sans `Domenia.Ad` : `dashboard.summary` → `source.unavailable`, `session.info` répond « non connecté ».
40. Garde de simulation : une opération `Write` de test est refusée (`simulation.readOnly`) et une `NetworkRead` non
    servie l’est aussi (`simulation.unavailable`), sans que leur gestionnaire s’exécute ; une `NetworkRead` marquée
    servie et une `LocalRead` passent ; les lectures réseau de l’Accueil sont marquées servies.

**`SimulationIsolationTests.cs` et `BridgeJsonTests.cs`**

41. `Domenia.Simulation` ne référence que `Domenia.Core` et la bibliothèque de base : ni `System.DirectoryServices*`,
    ni `System.Management`, ni `System.Net.*`, ni `Microsoft.Web.WebView2`, ni `Domenia.Ad`, `Domenia.Inventory`,
    `Domenia.Store`.
42. `IDirectorySource` n’expose aucune méthode d’écriture (aucun nom en `Write`, `Set`, `Delete`, `Move`, `Reset`,
    `Unlock`, `Enable`, `Disable`).
43. Aucun nom de propriété JSON des réponses ne contient `password`, `pwd` ni `secret` ; les records de l’instantané
    n’ont aucun champ de mot de passe LAPS ni de clé BitLocker (vérifié par réflexion).
44. `BridgeJson` : dates UTC en `Z` à la seconde, `DateOnly`, énumérations camelCase, `error` omis seulement quand il
    est nul.

**Ajouts après la revue du 21 octobre 2026**

45. Un résumé qui chevauche une actualisation ne remet pas en mémoire l’état d’avant la manche : la réactivation d’un
    widget repart de la dernière manche (`DashboardOperationsTests`).
46. Actualisation d’un widget de calcul local : délai de 400 à 900 ms (annulée à 300 ms), aucune manche
    (`DashboardOperationsTests`).
47. `watchlist` sans relevé d’inventaire récent : jamais `ok`, détail « disques et redémarrages non évalués » ; avec un
    inventaire récent sans point : `ok` (`DashboardCalculatorTests`).
48. Refus du pont signalés par `Refused` avec leur code et le nom déclaré ou bien formé, jamais un nom mal formé
    (`BridgeTests`).

## 9. Ordre de réalisation

1. Core : modèles d’annuaire et de relevés, `AdValues`, `AccountState`, `DistinguishedName`, `WindowsRelease`,
   `FrenchText`, `DashboardPolicy`, `WidgetCatalog`, `DashboardCalculator`, `OperationJournal`, `DashboardService`,
   `ModeResolver`, `AppInfoBuilder`, `UnavailableDirectorySource` ; tests 1 à 5 et 17 à 30.
2. Simulation : `SeededRandom`, `FrenchNames`, profil, générateur, manches, source ; tests 6 à 16 et 41 à 43.
3. Pont : `BridgeJson`, `BridgeArguments`, opérations, garde ; tests 31 à 40 et 44.
4. Application : `Main(args)`, sonde de jonction, composition, titre ; ajout du projet à `Domenia.sln`.
5. Compilation dans la VM après chaque lot (`tools/sync-vm.sh` puis `tools/build-vm.ps1`) ; tests à la toute fin.

La page Accueil (`web/`) consomme le contrat tel quel ; `web/js/mock.js` doit renvoyer les mêmes formes pour l’aperçu
dans un navigateur. Il porte `SeededRandom` à l’identique (SplitMix64 en entiers 64 bits, sous-suites nommées par FNV-1a 64,
tirages sans biais par rejet) : les 13 instantanés quotidiens (`history`, `history/accounts`) sont les mêmes nombres que
ceux du moteur, donc les mêmes tendances à 7 jours et les mêmes courbes ; comme le moteur, il ne montre l’historique des
postes que pour l’OU où il a été relevé (OU Postes avec ses sous-OU), jamais au prorata d’une autre OU.

## 10. Points ouverts

1. ~~**Persistance de « Mesure active »**~~ : tranché le 21/10 (« fais au plus intelligent ») et réalisé : classe
   `LocalWrite`, préférences locales (`preferences-simulation.json` en simulation), `OPERATIONS.md` § 7.
2. ~~**Réglage `Auth.DemoProvider` de Domenia 1**~~ : tranché le 21/10 (« ok, fais au mieux ») et réalisé : règle 4
   du § 2.1, raison `configuration`.
3. **Fins de service** (`fleet.eos`, `fleet.win10`) : hors de cette étape ; la table de Domenia 1 sera portée avec ces
   widgets. Les 23 postes Windows 10 22H2 de la simulation deviendront alors des alertes « fin de service ».
4. ~~**Choix de l’OU de travail**~~ : tranché le 21/10 (« au plus pratique et logique ») et réalisé côté moteur :
   `directory.ou.children`, `directory.ou.search`, `session.setScope` (`OPERATIONS.md` § 8 à 11), OU mémorisée par
   domaine ; `OU=Postes` reste l’OU par défaut de la simulation.
5. `docs/FEATURES.md` n’existe pas encore : le mode simulation y sera inscrit comme amélioration de la démonstration
   D002 à D004 (statut `ameliore`). `ARCHITECTURE.md` liste `Domenia.Simulation` depuis le 21 octobre 2026.

## 11. État de la réalisation (21 octobre 2026)

Code écrit et compilé dans la VM Domenia (0 erreur, 0 avertissement) ; **tests écrits, non exécutés** (décision de David :
tests à la toute fin). Côté `web/` : `js/mock.js` est réécrit sur l’annuaire fictif et rend les formes exactes du
contrat (aperçu dans un navigateur) ; `js/pages/accueil.js` suit le contrat (`distribution.lead` nul, bannière, texte
d’introduction du mode non connecté) et, en simulation, parle d’annuaire fictif plutôt que de base locale (puce « Annuaire
fictif lu il y a 12 min », onglet « Données fictives ») ; `lastSeenAt` nul s’y lit « aucune réponse au ping ».
`js/router.js` et `js/app.js` portent le signal `data-ready` du mode capture (`CAPTURE.md` § 5).

| Lot | Fichiers |
|---|---|
| Core | `Startup/` (`AppMode`, `ModeResolver`, `AppInfo`), `Directory/` (modèles, `AdValues`, `AccountState`, `DistinguishedName`, `DirectorySource`, `SessionModels`, `UnavailableDirectorySource`), `Fleet/` (relevés, `LocalDays`, `WindowsRelease`), `Dashboard/` (`DashboardModels`, `WidgetCatalog` avec `DashboardPolicy`, `DashboardCalculator`, `DashboardService`, `OperationJournal`), `Text/FrenchText`, `DomeniaOperationException` (avec `DomeniaErrors`) |
| Simulation | `SimulationOptions`, `SimulationProfile`, `SeededRandom`, `FrenchNames`, `SimulatedWorld` (avec `PresenceModel`, `PresenceRounds`), `SimulatedWorldGenerator`, `SimulatedDirectorySource` |
| Pont | `BridgeJson`, `BridgeArguments`, `AdmissionGuards`, `Operations/DashboardOperations` ; `BridgeDispatcher` (garde d’admission, `DomeniaOperationException`) ; `BridgeResponse.Error` omis seulement s’il est nul |
| Application | `Program.Main(args)`, `Interop/DomainJoin`, `Composition`, `HostOperations` (`app.info` avec le mode), `TechnicalLog`, titre de fenêtre |
| Outils | `tools/build-vm.ps1` ajoute à `Domenia.sln` tout `.csproj` de `src/` et `tests/` qui n’y est pas encore |
| Tests | `ModeResolverTests`, `SimulationGeneratorTests`, `DashboardCalculatorTests`, `DashboardOperationsTests`, `SimulationIsolationTests`, `BridgeJsonTests`, `TestSupport` (horloge fixe, annuaires écrits à la main, pont simulé) |

Écarts avec la conception ci-dessus :

- `DirectoryState` porte aussi le journal tenu par la source (`Journal`) : le journal fictif vient de la simulation, celui de
  la session est ajouté par `DashboardService`.
- `FleetObservations` n’a pas de champ `SeenToday` : les postes vus aujourd’hui se déduisent de `PresenceMeasure.LastOnlineAt`
  (dernière réponse), qui ne recule jamais pendant la journée.
- `session.info` est déclarée dans `Operations/DashboardOperations.cs` avec les opérations `dashboard.*` (pas de
  `SessionOperations.cs` séparé).
- Détection de jonction : `NetGetJoinInformation` renvoie le nom **NetBIOS** du domaine ; le nom DNS (`cnamts.local`) est lu
  dans la LSA locale par `DsRoleGetPrimaryDomainInformation` (sans réseau, et non le suffixe DNS principal du poste, qui
  peut différer du domaine AD), avec repli sur le nom NetBIOS.
- `MeasureFamily` a une quatrième valeur, `LocalComputation` : l’actualisation d’un widget de calcul local passe par
  `IDirectorySource.RefreshAsync` (même délai que les autres familles en simulation, simple relecture locale en mode
  annuaire).
- `DashboardService` ne remplace l’état en mémoire par celui d’un résumé que si aucune actualisation (ni aucun autre
  résumé) ne l’a remplacé pendant sa lecture (numéro de version de l’état).
- Verrouillés : `lockoutTime` entre référence − 28 et − 13 minutes (dans la plage prévue de 2 à 28 minutes), pour rester
  antérieur à la lecture fictive de l’annuaire (référence − 12 minutes).
- `distribution.lead` vaut `null` seulement si le périmètre ne contient aucun ordinateur activé (cas absent de la simulation).

### Ajouts du 21 octobre 2026 au soir (plateforme)

Code écrit et compilé dans la VM (Debug et Release, 0 erreur, 0 avertissement) ; **tests écrits, non exécutés**.

- Modules d’opérations trouvés par réflexion, contexte de services, lecteurs d’écran : `PLATFORM.md`.
- `LocalWrite`, préférences locales (`Domenia.Store/Preferences/FilePreferenceStore.cs`), persistance de
  `dashboard.widget.setEnabled`, OU de travail (`Domenia.Core/Session/WorkingScope.cs`), arborescence des OU
  (`Domenia.Core/Directory/Tree/`, `Domenia.Simulation/Screens/SimulatedDirectoryTreeReader.cs`), `Auth.DemoProvider`
  (`Domenia.Core/Startup/LegacyConfiguration.cs`, `Domenia.Store/Configuration/LegacyConfigurationFile.cs`).
- Tests ajoutés (à exécuter à la fin) : `PlatformTests` (découverte des modules et des lecteurs, erreurs de composition,
  garde de simulation avec `LocalWrite`), `PreferencesTests` (document atomique, illisible mis de côté, échec d’écriture,
  widgets mémorisés et restaurés), `DirectoryTreeTests` (formes exactes, ordre français, chemins, nombres, recherche sans
  accent, bornes), `WorkingScopeTests` (choix, mémorisation par domaine, restauration, OU disparue, tout le domaine,
  historique d’une autre OU, manche bornée à l’OU), `LegacyConfigurationTests` (ordre des règles, booléen strict, fichiers
  invalides), `CaptureArgumentsTests` (`CAPTURE.md` § 14), `tests/tools/vm-lock-test.sh` (verrou de la VM).
