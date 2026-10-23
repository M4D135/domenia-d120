# Écran « Poste » — opérations, écritures et mode annuaire

Console d’un poste de travail (Domenia 1 : onglets Poste, Tableau du poste, Administration, Sessions, Services,
Inventaire, Logiciels, Santé, WMI, Sécurité). Module `PosteOperations` (`Domenia.Bridge/Operations/PosteOperations*.cs`),
lecteur `IPosteReader` (`Domenia.Core/Screens/Poste/IPosteReader.cs`), lecteur simulé
`SimulatedPosteReader` (`Domenia.Simulation/Screens/Poste/`), écritures `Domenia.Core/Writes/Poste/` et
`Domenia.Simulation/Writes/Poste/`, services de l’hôte `Domenia.App/Poste/` (§ 6), page `web/js/pages/poste.js` et
`web/js/pages/poste/*.js`, styles `web/css/pages/poste.css`. Fonctions de Domenia 1 : `PST-001` à `PST-117`
(`docs/features.json`), état dans `docs/status/poste.json`.

## 1. Principes

- **Lecture seule par défaut.** `poste.open` ne lit que la base locale (fiche de l’annuaire, observations enregistrées,
  dernier inventaire) : aucune sonde réseau, aucun ping. Chaque lecture réseau part d’un geste (bouton, ouverture depuis
  la liste pour le seul ping de vérification et, si l’option est cochée, l’utilisateur connecté, PST-051), vise **un seul
  poste**, est bornée dans le temps et peut être arrêtée par type (`poste.collect.stop`).
- **Jamais tout le domaine.** Les listes (`poste.list`, `poste.groups.search`, `poste.secrets.index`) portent sur l’OU de
  travail ou la base locale, bornées (1 000 postes, 50 groupes, 50 000 postes pour l’index). Aucune opération de l’écran
  ne parcourt le domaine.
- **Écritures par le circuit** (`docs/WRITES.md`) : `poste.<verbe>.plan` (une lecture) prépare un plan scellé, la page le
  montre, l’opérateur confirme (nom tapé pour les gestes dangereux), `write.execute` enregistre le reçu, envoie, relit.
  Rien n’est rejoué automatiquement ; un jeton ne sert qu’une fois.
- **Données honnêtes.** Chaque valeur est un `PosteFact` : valeur, état (`observed`, `estimated`, `refused`,
  `unavailable`, `unknown`), source, limite, conseil et date. Un refus ou une lecture partielle n’est jamais présenté
  comme « aucun » ; une mesure inconnue vaut `null` ; un contrôle non lu est « Non lu », jamais « Rien à signaler ».
- **Aucun secret dans la page ni dans un journal.** Les valeurs LAPS et BitLocker ne passent que par la fenêtre
  sécurisée de l’hôte (§ 6) : jamais dans une réponse du pont, le journal des opérations, le journal technique, un reçu ou
  un export. Les arguments d’un programme lancé à distance ne sont gardés ni dans le plan ni dans le reçu (empreinte et
  longueur seulement, PST-028).

## 2. Routes de la page

`#/poste` affiche le choix d’un poste (liste de l’OU de travail, recherche locale, filtres, postes ouverts récemment
gardés dans la mémoire de la page, jamais sur le disque ni avec un nom d’utilisateur). `#/poste?dn=…` ou
`#/poste?nom=PC-PAR-0001` ouvre la console. Paramètres :

| Paramètre | Valeurs | Effet |
|---|---|---|
| `vue` | `ensemble`, `inventaire`, `diagnostic`, `releves`, `intervenir`, `secrets` | Vue ouverte. |
| `onglet` | noms de Domenia 1 (`TabWmi`, `TabSoftware`, `TabSessions`, `TabComputerServices`, `TabSecurity`…) et onglets internes (`materiel`, `logiciels`, `services`, `processus`, `sessions`, `reseau`, `rapide`, `lent`, `evenements`, `wmi`, `jonction`) | Vue et onglet (PST-048). |
| `panneau` | `postes`, `redemarrer`, `executer`, `groupe`, `deplacer`, `fiche` | Ouvre un panneau ; `executer` exige l’autorisation d’intervention. |
| `verifier` | `1` | Ouverture depuis la liste : un seul ping (et l’état en direct si l’option `openReadsConsole` est cochée), puis le paramètre est retiré de l’adresse. |
| `essai` | `inventaire`, `logiciels`, `services`, `processus`, `sessions`, `diagnostic`, `rapide`, `lent`, `evenements`, `wmi`, `sondes`, `laps`, `bitlocker`, `index`, `live`, `detection`, `connexions` | **Simulation seulement** : lance une lecture pour les captures et les guides ; ignoré en mode annuaire. Jamais une révélation de secret. |

La page de l’atelier de requêtes (écran Requêtes, autre lot) est ouverte par `#/requetes?cible=poste&dn=…` (bouton
« Atelier ») et `#/requetes?cible=poste&dn=…&sonde=<id>` (« Ouvrir dans l’atelier » d’une sonde, PST-111).

## 3. Opérations

Classe : celle du mode annuaire. En simulation, les lectures marquées « servie » sont admises (lectures en mémoire du
monde fictif, latence simulée) ; les plans sont `LocalRead` en simulation et `NetworkRead` en mode annuaire, comme
`accounts.unlock.plan`.

### 3.1 Lectures locales, état de session et préférences

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `poste.list` | `LocalRead` | `{ text?, limit? }` (texte ≤ 100, limite 1–1 000, 500 par défaut) | `PosteList` : postes de l’OU de travail avec présence, santé (niveau, points), utilisateur, système, site, dates. |
| `poste.open` | `LocalRead` | `{ dn }` | `PosteConsole` : `computer`, `header`, `association`, `live`, `inventory`, `board` (santé avec la politique de l’OU, fiches, ressources, disques, protection, activité, comptages, sections), `secrets` (résumé non secret), `consent`, `options`, `notes`. Lie les autorisations à la session (§ 5). |
| `poste.host` | `LocalRead` | `{}` | `{ secretWindow, toolLauncher, fileExport, simulation, openReadsConsole }` : services de l’hôte présents (§ 6) et option de l’écran. |
| `poste.option.set` | `LocalWrite` | `{ name: openReadsConsole, value }` | Préférence locale `poste.openReadsConsole` (PST-051) ; aucune action sur un poste. |
| `poste.inventory.cached` | `LocalRead` | `{ dn }` | `InventoryResult` du dernier inventaire (cette session, sinon le dernier validé en base locale) avec ses lignes, sa date et sa provenance ; `null` sans inventaire (PST-029, PST-036). |
| `poste.software.cached` | `LocalRead` | `{ dn }` | `SoftwareResult` tiré du dernier inventaire (PST-025) ; `columns` dit les colonnes lues (PST-043). |
| `poste.readings` | `LocalRead` | `{ dn }` | `ReadingsResult` : 15 lectures interprétées, fraîcheur (récente < 3,5 j, vieillissante, périmée > 7 j), prévision de saturation, BIOS comparé à la référence du modèle. |
| `poste.probe.details` | `LocalRead` | `{ dn, probe, page? }` | Valeurs enregistrées d’une sonde (100 lignes par page), lecture interprétée et contrat de la sonde (PST-074). |
| `poste.commands` | `LocalRead` | `{ dn }` | `PosteCommands` : Enter-PSSession, Invoke-Command, mstsc, UNC, consoles MMC ; valeurs entre apostrophes, jamais de mot de passe. |
| `poste.suite.plan` | `LocalRead` | `{ dn, tool: pesto\|filpro }` | `{ tool, plan, launched: false, canLaunch, text }` : champs déclarés et validés seulement (PST-020). |
| `poste.groups.search` | `LocalRead` (simulation), `NetworkRead` (annuaire) | `{ text? }` | Au plus 50 groupes (`{ dn, name }`) dont le nom contient le texte, sans accent ni casse ; en mode annuaire, repli LDAP sous la racine (§ 8.1). |
| `poste.account.find` | `LocalRead` | `{ login }` (1–100) | `UserRef` du compte d’une session (sAMAccountName, domaine ou suffixe UPN retiré), ou `null` (PST-073). |
| `poste.running` | `Local` | `{}` | Relevés en cours de la session, tous postes : `[{ dn, computer, kind, label, since }]` (PST-052). |
| `poste.collect.stop` | `Local` | `{ dn, kind? }` (`inventory`, `diagnostic`, `probes`, `detection` ; tous sans `kind`) | `{ stopped, text }` : arrête un relevé du poste ; le lecteur rend ce qu’il a déjà lu (résultat partiel). |
| `poste.consent.grant` | `Local` | `{ dn, kind: intervention\|readFallback, minutes? }` (1–15, 5 par défaut) | `{ consent, history }`. Ne lance rien. Refusé (`poste.writePending`) tant qu’une écriture sur ce poste reste « à vérifier ». |
| `poste.consent.revoke` | `Local` | `{ dn, kind }` | `{ removed, consent, history }`. |
| `poste.consent.history` | `Local` | `{}` | Autorisations accordées, refusées, retirées, expirées ou utilisées dans la session. |
| `poste.secret.state` | `Local` | `{}` | `SecretWindowState` : ouverte, masquée ou fermée, échéance, prolongation restante ; jamais la valeur. |
| `poste.secret.hide` | `Local` | `{}` | Ferme la fenêtre sécurisée et efface la valeur (changement de vue ou de poste, « Masquer maintenant »). |
| `poste.dsreg.analyze` | `Local` | `{ dn, text, collectedAs: endUser\|admin\|unknown, endUser? }` | `DsregAnalysis` (128 Kio au plus) : jonction, mode, SSO évaluable seulement pour un texte collecté sous l’utilisateur final (PST-033). |
| `poste.bios.reference` | `LocalWrite` | `{ dn, action: approve\|remove }` | Préférence locale `poste.biosReferences.<sha256 du domaine>` ; aucune action sur le poste (PST-080). |
| `poste.export.save` | `LocalWrite` | `{ dn, kind, files: [{ part: lignes\|sources\|liste, csv }] }` (1 ou 2 parties, 8 Mio au plus) | `PosteExportResult` : fichier choisi par l’opérateur dans la boîte « Enregistrer sous » de Windows, nommé `Domenia-<poste>-<kind>-AAAAMMJJ-HHmm.csv`, la seconde partie à côté (`…-sources.csv`), UTF-8 avec BOM (PST-006, PST-039, PST-047). Sans hôte : `poste.hostUnavailable`, la page copie la liste. |

### 3.2 Lectures réseau (servies en simulation)

| Opération | Arguments | Résultat, bornes |
|---|---|---|
| `poste.ping` | `{ dn }` | `PresenceReading` : un écho ICMP, enregistré avant d’être montré (PST-050) ; un temps inconnu n’est jamais écrit « 0 ms ». |
| `poste.live` | `{ dn }` | `PosteLive` : présence, dernier démarrage, utilisateur console, sessions. |
| `poste.inventory` | `{ dn, deep }` | `InventoryResult` : lignes traduites (valeur brute gardée), état par source, catégories, `partial`, `notice`, `noticeAction` (`readFallback` quand CIM refuse). Rapide 55 s, complet 150 s ; à l’arrêt ou au budget, résultat partiel enregistré (sources restantes « Interrompu », PST-037). Événements `poste.inventory:progress`. |
| `poste.software` | `{ dn, perUser, store, updates }` | `SoftwareResult` : registre Uninstall 64/32 bits, SCCM, ruches des profils, Appx ; jamais `Win32_Product`. 130 s (200 s avec les profils). |
| `poste.services` | `{ dn }` | `ServicesResult` : 500 instances au plus, profil attendu (15 services), arrêts attendus. |
| `poste.processes` | `{ dn }` | `ProcessesResult` : deux lectures espacées, part du processeur mesurée. |
| `poste.events` | `{ dn, preset, hours?, max? }` | `EventsResult` : préréglages `Startup`, `Crash`, `Disk`, `Policy`, `Updates`, 1–720 h, 1–200 événements, bornes dites. |
| `poste.sessions` | `{ dn }` | `SessionsResult` (WTS) : lignes sans compte comptées, jamais listées. |
| `poste.restart.sessions` | `{ dn }` | `RestartSessions` : sessions lues avant un redémarrage ; une lecture impossible est dite, le redémarrage différé reste possible (PST-014). |
| `poste.diagnostic` | `{ dn }` | `DiagnosticResult` : DNS, ping, ports 135/445/3389/5985/5986, CIM, C$, WinRM, replis, système, disque ; couches et étape bloquante ; 45 s ; à l’arrêt, contrôles restants « non tentés ». Événements `poste.diagnostic:progress`. |
| `poste.quickDiag` | `{ dn }` | `QuickDiagResult` : cinq contrôles (système, dernier démarrage, disque C:, ports 135/445/5985, services Winmgmt, RpcSs, WinRM, LanmanServer), 20 s annoncées, aucun repli (PST-004). |
| `poste.slow` | `{ dn }` | `SlowTriage` : pistes classées (mémoire, processeur mesuré, disques, redémarrage, démarrage automatique, journaux 72 h, lien réseau). |
| `poste.wmi.namespaces` | `{ dn, parent? }` | Espaces de noms (root et enfants directs). |
| `poste.wmi.classes` | `{ dn, ns }` | Classes, celles du fournisseur MSI marquées bloquées. |
| `poste.wmi.query` | `{ dn, ns, cls, where?, limit? }` | `WmiQueryResult` : `SELECT *` validé, 1–500 instances (25 par défaut), aucune méthode. Refus : `poste.queryRefused`. |
| `poste.probes.collect` | `{ dn, probes? }` (1–64 sondes du catalogue ; celles du tableau par défaut) | `ReadingsResult` : seules les sondes demandées sont relevées, une fois, enregistrées puis interprétées ; la page demande une confirmation avant (PST-110). Événements `poste.probes.collect:progress`. |
| `poste.logonByDc` | `{ dn }` | `LogonActivity` : `lastLogon` sur chaque contrôleur (PST-114). |
| `poste.lastUser.detect` | `{ dn }` | `LastUserDetection` : association locale, CIM, LogonUI, WinRM, profils, tâche SYSTEM unique (seulement avec la lecture de repli quand CIM refuse) ; 25 s ; une association existante n’est jamais écrasée (PST-117). Événements `poste.lastUser.detect:progress`. |
| `poste.laps` | `{ dn }` | `LapsView` : métadonnées, sans valeur (PST-063). |
| `poste.laps.reveal` | `{ dn }` | `SecretShown` (§ 6) : la valeur est montrée dans la fenêtre sécurisée, jamais renvoyée. Sans fenêtre : `poste.hostUnavailable` avant toute lecture. |
| `poste.bitlocker.list` | `{ dn }` | `BitLockerList` : objets de récupération sous le poste (un niveau, 256 au plus), identifiant de récupération complet (`keyGuid`) et ses 8 premiers caractères, sans clé (PST-053). |
| `poste.bitlocker.reveal` | `{ dn, key, expectedId }` | `SecretShown` (§ 6) ; la clé doit être un enfant direct du poste (`poste.keyNotChild`) et l’identifiant relu doit être `expectedId` (`poste.keyMismatch`, aucune valeur, PST-055). |
| `poste.account.other` | `{ dn, resource: laps\|bitlocker }` | `OtherAccountResult` : un autre compte est proposé par l’invite Windows (mot de passe jamais vu par Domenia) ; accepté, le refus mémorisé est levé pour cette seule ressource (PST-060, PST-062). |
| `poste.secrets.index` | `{}` | `SecretsIndex` de l’OU de travail : clés BitLocker comptées, état de lecture, expiration LAPS, 50 000 postes au plus ; aucune clé ni valeur ; les métadonnées d’un ancien détenteur du nom sont écartées (PST-065, PST-066). |
| `poste.tool.open` | `{ dn, tool: rdp\|c\|compmgmt\|eventvwr\|services }` | `ToolLaunch` : outil ouvert par le lanceur de l’hôte (§ 6) ; en simulation rien n’est lancé, la commande est montrée (PST-009, PST-022). Sans lanceur : `poste.hostUnavailable`. |
| `poste.suite.launch` | `{ dn, tool: pesto\|filpro }` | `ToolLaunch` : Pesto ou FILPRO ouvert après contrôle de l’empreinte SHA-256 et du contrat `suite-contract.json` (`DomeniaSuiteContract/1`), champs déclarés seulement ; rien en simulation (PST-020). |

### 3.3 Erreurs propres à l’écran

| Code | Cause |
|---|---|
| `poste.unknown` | Le DN ne désigne aucun poste (compte utilisateur, objet supprimé). |
| `poste.unreachable` | Le poste ne répond pas (aucune conclusion sur son état), ou budget atteint avant toute lecture. |
| `poste.consentRequired` | Exécuter un programme sans autorisation d’intervention active sur ce poste. |
| `poste.writePending` | Autorisation demandée pendant qu’une écriture sur ce poste reste « à vérifier » (PST-010). |
| `poste.refused` | Demande refusée par une règle (mode inconnu, message trop long, WinRM désactivé, valeur invalide, OU de travail absente). |
| `poste.queryRefused` | Requête WMI refusée (espace, classe, filtre, fournisseur MSI). |
| `poste.cimRefused` | CIM refusé (DCOM filtré, WinRM fermé) pour une lecture sans repli (services, processus, événements, sessions, WMI, tri d’un poste lent). |
| `poste.keyNotChild` | Clé BitLocker hors du poste ouvert. |
| `poste.keyMismatch` | Identifiant de récupération relu différent de la clé choisie : aucune valeur. |
| `poste.busy` | Un relevé du même type tourne déjà sur ce poste : rien n’est relancé ni remplacé (PST-052). |
| `poste.cancelled` | Relevé arrêté avant toute lecture (au-delà, le lecteur rend un résultat partiel). |
| `poste.hostUnavailable` | Service de l’hôte absent (aperçu, tests) : fenêtre sécurisée, lanceur ou « Enregistrer sous ». Rien n’est lu ni lancé. |

## 4. Écritures (circuit `write.execute`)

| Plan | Arguments | Type (`Kind`) | Confirmation | Vérification |
|---|---|---|---|---|
| `poste.account.plan` | `{ dn, enable }` | `poste.accountState` | nom tapé pour désactiver | relecture de `userAccountControl` |
| `poste.profile.plan` | `{ dn, description?, location?, managedBy? }` | `poste.profile` | simple ; seuls les attributs modifiés partent | relecture des attributs |
| `poste.rename.plan` | `{ dn, name }` (1–63, étiquette DNS) | `poste.rename` | nom tapé ; seul le CN change (Rename-ADObject) : `sAMAccountName`, `dNSHostName` et nom Windows inchangés, le poste continue de s’authentifier | relecture par GUID (CN, DN et `sAMAccountName` inchangé) |
| `poste.group.plan` | `{ dn, group, add }` | `poste.group` | simple (ajout), nom tapé (retrait d’un groupe protégé) | relecture de `member` |
| `poste.move.plan` | `{ dn, ou }` | `poste.move` | nom tapé | relecture par GUID |
| `poste.restart.plan` | `{ dn, mode: delayed\|now, minutes?, message? }` (1–60 min, message ≤ 400) | `poste.restart` | nom tapé pour « maintenant » ; la page ne coche jamais « Immédiat » d’office (PST-013) | redémarrage programmé ou dernier démarrage |
| `poste.restartCancel.plan` | `{ dn }` | `poste.restartCancel` | simple | plus de redémarrage programmé |
| `poste.gpupdate.plan` | `{ dn }` | `poste.gpupdate` | simple ; WinRM requis | code de retour de gpupdate |
| `poste.service.plan` | `{ dn, name, action: start\|restart\|stop }` | `poste.service` | nom tapé pour redémarrer ou arrêter ; type de démarrage jamais modifié | relecture de l’état du service |
| `poste.run.plan` | `{ dn, mode: system\|interactive, command, arguments?, user?, elevated? }` | `poste.run` | autorisation d’intervention **et** nom tapé ; les arguments restent en mémoire de la session sous leur empreinte jusqu’à l’envoi ou l’expiration du plan, le plan et le reçu ne portent que l’empreinte et la longueur | envoi de la tâche seulement (l’exécution du programme n’est pas vérifiée) ; autorisation et arguments revérifiés juste avant l’envoi (`write.stale`) |
| `poste.wake.plan` | `{ dn }` | `poste.wake` | simple ; Wake-on-LAN activé, carte valide, sous-réseau autorisé | ping après le délai annoncé |

En simulation, les écritures annuaire s’appliquent à la surcouche en mémoire (`SimulatedDirectoryOverlay.UpdateComputer`,
`UpdateGroup`, ajoutés comme prévu par `WRITES.md`) et les actions distantes à l’état simulé du poste
(`PosteSimulation`) : redémarrage programmé visible dans les notes de la console, service relu, réveil enregistré.

## 5. Autorisations de session (`PosteSession`)

- **Intervention** (PST-010, PST-017) : 1 à 15 minutes, un seul poste, exigée par `poste.run.plan` et revérifiée juste
  avant l’envoi. Le décompte s’affiche dans l’en-tête ; « Retirer » la lève tout de suite ; elle expire seule.
- **Lecture de repli** (PST-011, PST-023) : une seule lecture par tâche planifiée unique quand CIM (DCOM et WinRM) refuse,
  consommée une fois par l’inventaire, les logiciels, le diagnostic ou la détection de l’utilisateur, distincte de
  l’intervention. Sans elle, la lecture rend « non lu » (avec l’action « Autoriser une lecture de repli… ») au lieu de
  basculer. PsExec n’est pas livré dans le pack.
- Aucune autorisation n’est accordée tant qu’une écriture sur le poste reste « à vérifier » (`poste.writePending`, le refus
  est inscrit dans l’historique) ; reçus illisibles : refus (fail closed).
- Liées au compte et au domaine de la session de l’annuaire : un changement de session les efface toutes, arrête les
  relevés et oublie les arguments en attente.
- L’historique (`poste.consent.history`) garde accordée, refusée, retirée, expirée, utilisée ; il vit dans la session seulement.
- **Relevés** (PST-052) : un relevé par poste **et par type** (`Inventory`, `Diagnostic`, `Probes`, `Detection`) ; un
  diagnostic n’arrête jamais un inventaire ; un second relevé du même type est refusé (`poste.busy`) ; « Arrêter » vise un
  type ; l’en-tête nomme les relevés en cours, y compris ceux d’un autre poste.

## 6. Secrets et services de l’hôte (`Domenia.App/Poste/`)

`OPERATIONS.md` § 1.2 interdit tout mot de passe ou clé dans une réponse : ce lot le respecte sans exception. Les
fonctions PST-055 à PST-058, PST-063 et PST-064 de Domenia 1 révèlent **une** valeur sur un geste explicite ; Domenia 2 la
montre dans une **fenêtre sécurisée native** de l’application, jamais dans la page :

- `IPosteSecretWindow`, `IPosteToolLauncher` et `IPosteFileExport` (Core, `PosteHost.cs`) sont trouvés par la composition
  comme des lecteurs d’écran : `PosteHostServices` (App) a un seul constructeur public qui prend la source d’annuaire,
  appelé sur le fil de l’interface ; il y crée un contrôle de marshalling, puis chaque fenêtre est créée sur ce fil.
  Aucun fichier partagé n’est modifié. Les tests et l’aperçu n’ont pas d’hôte : révélation, ouverture d’outil et
  enregistrement répondent `poste.hostUnavailable` avant toute lecture.
- **Fenêtre sécurisée** (`SecretWindowForm`) : au-dessus de Domenia, hors de la barre des tâches, exclue des captures
  d’écran (`SetWindowDisplayAffinity`) ; la valeur seule (huit blocs numérotés pour une clé, un caractère par case pour un
  mot de passe, chiffres et symboles distingués), l’identifiant complet à comparer avec l’écran du poste, un décompte de
  30 s, une prolongation de 30 s, « Masquer maintenant » (et Échap). Elle **masque la valeur quand elle perd le focus**
  et la réaffiche d’un clic sans nouvelle lecture (PST-057), l’efface à l’échéance ou à la fermeture. Couleurs du système :
  thème de Windows et contraste élevé respectés.
- **Copie protégée** (PST-058) : formats `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0`,
  `CanUploadToCloudClipboard = 0` ; après 30 s, le presse-papiers est vidé **seulement s’il contient encore la valeur** ;
  la copie est journalisée avec l’identifiant, jamais la valeur.
- La page ne reçoit que `SecretShown` (type, poste, identifiant, GUID, échéance, règles, mention fictive) et suit la
  fenêtre par `poste.secret.state` ; elle la ferme (`poste.secret.hide`) au changement de vue, de poste ou d’écran.
  `SecretReading` (la lecture interne) exclut sa valeur de toute forme JSON et de `ToString`.
- **Lanceur** : `mstsc /v:`, Explorateur sur `\\poste\C$`, `mmc compmgmt.msc|eventvwr.msc|services.msc /computer:` ; avec
  un compte d’exploitation déclaré, connexion préalable à `C$` ou `IPC$` par `WNetAddConnection3` avec l’invite Windows
  (le mot de passe est saisi et gardé par Windows). Aucun interpréteur de commandes, aucun argument venu de la page
  autre que le nom du poste validé. Outils de la suite : empreinte SHA-256 de l’exécutable comparée à la configuration,
  contrat `suite-contract.json` (16 Kio au plus) relu à côté, champs déclarés et validés seulement ; sans contrat reconnu,
  ouverture sans argument. Rien n’est lancé en simulation.
- **Enregistrer sous** : boîte de Windows sur le fil de l’interface, écriture hors de ce fil, UTF-8 avec BOM ; le journal
  ne garde que le nom des fichiers.

## 7. Simulation

Les données de chaque poste sont dérivées de façon déterministe de son GUID (`ScreenStream("poste").Fork(guid)`) :
modèle (six modèles, dont les noms de `SIMULATION.md`), mémoire et disque (cohérents avec `InventoryMeasure` de la base
locale), disque mécanique sur 7 % des fixes, usure élevée sur 2 %, BitLocker actif, suspendu ou absent, adresse IP par site
(10.10 à 10.50 /22), cause de lenteur, association (managedBy déclaré ou contradictoire, sinon utilisateur du site
observé ou historique, aucun pour 14 %), logiciels, démarrage automatique, services (WinRM arrêté sur 10 %, Spooler,
WSearch, Dnscache en panne çà et là), correctifs, historique des volumes, écrans, batterie, événements, tâches,
certificats ; antivirus refusé sur 3 %. Les postes qui ne répondent jamais au ping, les sondes en erreur et le ping filtré
(répond à WMI, jamais au ping) reprennent `World.Presence`. CIM refusé sur 4 % des postes joignables (lecture de repli
nécessaire). Lecture BitLocker refusée pour les postes de Marseille, lecture LAPS refusée pour ceux de Lille (refus
mémorisés, levés par un autre compte fictif). Index des secrets de la base locale écrit pour un ancien détenteur du nom sur
3 % des postes (écarté). Options de simulation : Wake-on-LAN activé sur 10.0.0.0/8, compte d’exploitation
`EXAMPLE\adm-j.martin`, Pesto et FILPRO non configurés.

## 8. Mode annuaire (vague 3)

### 8.1 Annuaire (LDAP, `Domenia.Ad`)

| Besoin | Requête | Attributs |
|---|---|---|
| Fiche du poste (`poste.open`, base) | Base sur le DN, contrôleur de la session | `name`, `cn`, `dNSHostName`, `sAMAccountName`, `objectSid`, `objectGUID`, `operatingSystem`, `operatingSystemVersion`, `description`, `location`, `managedBy`, `userAccountControl`, `whenCreated`, `whenChanged`, `pwdLastSet`, `lastLogonTimestamp`, `memberOf`, `msLAPS-PasswordExpirationTime`, `ms-Mcs-AdmPwdExpirationTime`, `primaryGroupID` |
| Liste (`poste.list`) | base locale de l’OU de travail (instantané du parc), aucune requête | — |
| LAPS, métadonnées | Base sur le DN | `msLAPS-PasswordExpirationTime`, `msLAPS-EncryptedPassword` (présence seulement, `attributeTypes` sans valeur), `ms-Mcs-AdmPwdExpirationTime` |
| LAPS, révélation | Base sur le DN, sur geste | `msLAPS-Password` ou `msLAPS-EncryptedPassword` (déchiffrement DPAPI-NG par l’API Windows), sinon `ms-Mcs-AdmPwd` ; la valeur va à la fenêtre sécurisée |
| BitLocker, liste | OneLevel sous le DN, `(objectClass=msFVE-RecoveryInformation)`, 256 au plus | `name`, `msFVE-RecoveryGuid`, `msFVE-VolumeGuid`, `whenCreated` ; jamais `msFVE-RecoveryPassword` |
| BitLocker, révélation | Base sur le DN de la clé (enfant direct vérifié) | `msFVE-RecoveryPassword` et `msFVE-RecoveryGuid` relu, comparé à `expectedId` |
| Index des secrets de l’OU | OneLevel ou Subtree borné à l’OU de travail, 50 000 au plus | présence d’objets `msFVE-RecoveryInformation` (comptés), expiration LAPS ; base locale : GUID et date de création pour écarter un ancien détenteur |
| Connexions par contrôleur | Base sur le DN, sur **chaque** contrôleur du domaine (liste de la session), 5 s chacun | `lastLogon` |
| Groupes | base locale (instantané) ; en repli : sous la racine, `(&(objectCategory=group)(name=*texte*))`, 50 au plus (d’où `NetworkRead` en mode annuaire) | `distinguishedName`, `name` |
| Compte d’une session | base locale, sinon Base sur la racine `(&(objectCategory=person)(sAMAccountName=…))` | `distinguishedName`, `displayName`, `objectGUID` |
| Écritures | `Modify` (`userAccountControl`, `description`, `location`, `managedBy`, `member` du groupe), `ModifyDN` (renommage : nouveau RDN `CN=` seulement ; déplacement `newSuperior`) | relecture par GUID après l’écriture |

### 8.2 Poste (WMI/CIM, WinRM, registre)

Transport : CIM sur WinRM (5985, Kerberos) quand `Remote.UseWinRM` est vrai, sinon CIM sur DCOM (135 puis ports
dynamiques) ; repli par tâche planifiée unique seulement avec l’autorisation de lecture de repli. Une session CIM par
relevé, fermée à la fin ; chaque source a son propre délai et son propre état.

| Catégorie ou sonde | Classes et sources |
|---|---|
| Système, matériel | `Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_ComputerSystemProduct`, `Win32_BIOS`, `Win32_Processor`, `Win32_PhysicalMemory`, `Win32_PhysicalMemoryArray`, `Win32_SystemEnclosure` |
| Disques | `Win32_LogicalDisk` (`DriveType=3`), `MSFT_PhysicalDisk` et `MSFT_StorageReliabilityCounter` (`root\Microsoft\Windows\Storage`) |
| Sécurité du démarrage | `Win32_EncryptableVolume` (`root\CIMV2\Security\MicrosoftVolumeEncryption`), `Win32_Tpm` (`root\CIMV2\Security\MicrosoftTpm`), registre `SYSTEM\CurrentControlSet\Control\SecureBoot\State` |
| Réseau | `Win32_NetworkAdapter`, `Win32_NetworkAdapterConfiguration` (`IPEnabled=TRUE`), `MSFT_NetFirewallProfile` et `MSFT_NetConnectionProfile` (`root\StandardCimv2`), `MSFT_NetTCPConnection` (complet) |
| Protection | `AntiVirusProduct` (`root\SecurityCenter2`), `MSFT_MpComputerStatus` (`root\Microsoft\Windows\Defender`) |
| Mises à jour | `Win32_QuickFixEngineering`, registre `SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`, clés de redémarrage en attente (CBS, Windows Update, `PendingFileRenameOperations`) ; fournisseur : Windows Update seul |
| Logiciels | `StdRegProv` : `Uninstall` 64 et 32 bits, ruches `HKU` des profils chargés (option), `CCM_InstalledProduct` (`root\ccm\cimodels`) si SCCM, Appx (option Store, par WinRM) ; jamais `Win32_Product` |
| Démarrage, tâches | `Win32_StartupCommand`, `MSFT_ScheduledTask` (`root\Microsoft\Windows\TaskScheduler`, complet) |
| Services | `Win32_Service` (500 au plus) ; écritures par `StartService`/`StopService` via WinRM, jamais `ChangeStartMode` |
| Processus | `Win32_PerfFormattedData_PerfProc_Process` lu deux fois, `Win32_Process` (chemin, propriétaire) |
| Périphériques | `Win32_PnPEntity` (`ConfigManagerErrorCode<>0`), `Win32_PnPSignedDriver`, `WmiMonitorID` et `WmiMonitorConnectionParams` (`root\wmi`), `Win32_Battery`, `BatteryFullChargedCapacity` (`root\wmi`), `Win32_Printer` |
| Sessions | API WTS (`WTSEnumerateSessions`, `WTSQuerySessionInformation`) ; repli `quser` par WinRM |
| Événements | `Get-WinEvent` filtré par préréglage (journal, fournisseurs, identifiants, fenêtre) |
| Certificats | magasin `Cert:\LocalMachine\My` par WinRM (complet) |
| Dernier utilisateur | association locale, `Win32_ComputerSystem.UserName`, registre `LogonUI\LastLoggedOnUser`, WinRM, `Win32_UserProfile` (`LastUseTime`), tâche SYSTEM unique (lecture de repli) |
| Sondes (33) | classes de `ProbeCatalog` (`Domenia.Core/Screens/Poste/ProbeCatalog.cs`), propriétés et filtres du contrat de chaque sonde |

### 8.3 Budgets

| Lecture | Budget |
|---|---|
| Ping | 1 écho, 1 000 ms |
| État en direct | 10 s |
| Inventaire rapide / complet | 55 s / 150 s (résultat partiel au-delà) |
| Logiciels | 130 s, 200 s avec les profils |
| Services | 90 s |
| Processus | 2 lectures espacées de 1 s, 20 s |
| Événements | 30 s |
| Diagnostic complet / rapide | 45 s / 20 s |
| Détection du dernier utilisateur | 25 s |
| Sondes | 60 s pour l’ensemble |
| Connexions par contrôleur | 5 s par contrôleur |
| Révélation d’un secret | 15 s |

## 9. Décisions appliquées et contrats avec les autres lots

- **WAPT abandonné** (décision de David du 22/10, PST-001) : aucun connecteur, aucune option de configuration, aucun
  service WAPTService dans les diagnostics, aucun fournisseur WAPT dans les faits de mise à jour (Windows Update seul).
- **Tests à la toute fin** (décision de David du 22/10) : la VM sert seulement à compiler (`tools/vm.sh poste build`) ;
  tests C# et scénarios E2E écrits, non exécutés.
- Fin de support Windows : **non retenue** (`DECISIONS.md`, « balec ») ; les règles de fin de support ne produisent aucun
  point d’attention.
- **Règles de santé** (PST-092, PST-093) : la console lit, sans jamais l’écrire, le livre des règles de santé du domaine
  tenu par l’éditeur des règles (ACC-024, lot Accueil) : préférence `accueil.health.<SHA-256 du DN racine en
  majuscules>`, `{ domainDn, default: { thresholds, disabledRules, customRules, suspensions }, scopes: [{ scopeDn,
  overrides: { thresholds, ruleStates, customRules, suspensions } }] }` (forme de Domenia 1
  `ConvertTo-DomeniaHealthPolicyBook`). Défauts puis OU ancêtres du poste, la plus proche en dernier ; seuils et états un
  par un, alertes et suspensions en listes entières ; partie illisible ignorée ; sans livre, seuils livrés avec Domenia 1
  (dit dans « Règles et seuils appliqués »). Les alertes sur requête enregistrée sont comptées et laissées à l’atelier.
- **Surcouche** : `SimulatedDirectoryOverlay.UpdateComputer` et `UpdateGroup` (partagés avec les lots Fiche et Comptes
  machine) : un seul `UpdateComputer` à garder à la fusion, appartenance `memberOf` symétrique.
- Thèmes : clair, sombre, contraste élevé ; animations en `transform`, `opacity`, `filter` ; « Animations réduites »
  respectée ; disposition sur la grille de 12 colonnes du kit (`.grid`, `.span-*`), cartes d’une rangée de même hauteur.

## 10. Collecteurs réels complémentaires (23 octobre 2026)

Le lecteur CIM collecte aussi le démarrage automatique, les périphériques en erreur, les écrans actifs, les batteries et leurs capacités, les pilotes non signés, les partages et les imprimantes. Le complet ajoute les métadonnées des tâches et les connexions TCP/UDP. Les plafonds sont de 200 entrées pour les petites listes, 32 écrans, 16 batteries, 1 000 tâches et 500 lignes par protocole réseau, avec sentinelle de troncature et budget global inchangé. Les requêtes restent des projections SELECT ; aucune méthode ni action de tâche n’est lue ou exécutée.

Les écrans sont joints par `InstanceName` selon [WmiMonitorID](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorid) et [WmiMonitorConnectionParams](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorconnectionparams). Un code inconnu reste non classé, y compris les adaptateurs virtuels. Les capacités des batteries ne sont rapprochées que par identité PnP ; zéro/valeur sentinelle de capacité n’est pas une mesure d’usure. Les valeurs des [imprimantes](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-printer) absentes ou inconnues ne deviennent plus un état sain. Les programmes de démarrage ne conservent que l’exécutable, jamais ses arguments ; leur éditeur reste inconnu tant qu’il n’a pas été vérifié.

Les [métadonnées des tâches](https://github.com/microsoft/wmi/blob/master/server23h2/root/microsoft/windows/taskscheduler/MSFT_ScheduledTask.go) ne comprennent ni action, ni arguments, ni principal. Dernier résultat et dates d’exécution restent non lus dans cette projection et le relevé le dit. Le raccordement de ces collecteurs à toutes les opérations de la console, les autres transports et la recette native restent à terminer. Quatre tests écrits et compilés seulement ; aucune exécution de tests dans ce lot.

## 11. Registre réel et incertitudes de configuration (23 octobre 2026)

Le chemin interne de registre autorise seulement `EnumKey`, `GetStringValue`, `GetDWORDValue` et `GetMultiStringValue` de [StdRegProv](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/regprov/stdregprov). Les ruches, chemins et valeurs d’inventaire sont explicitement admis ; la garde de l’atelier WQL reste inchangée. Chaque appel respecte le budget restant, le compte choisi et le chiffrement DCOM. La [vue du fournisseur 64 bits](https://learn.microsoft.com/en-us/windows/win32/wmisdk/requesting-wmi-data-on-a-64-bit-platform) est exigée ; son absence ne déclenche pas une lecture d’une autre vue présentée comme équivalente. Un rejet d’authentification arrête les autres appels registre et CIM de ce relevé.

Secure Boot, WSUS, les indicateurs de redémarrage et le site Netlogon utilisent ce chemin. Une valeur absente n’est pas un accès refusé ; un drapeau illisible ne devient pas zéro. Secure Boot désactivé ne prouve pas un BIOS hérité. Les obligations CBS/Windows Update sont distinctes des indices de renommage de fichiers ; les chemins de fichiers ne sont jamais conservés. Une date Windows Update sans fuseau reste du texte déclaré et ne participe pas à un calcul d’ancienneté. L’adresse du serveur WSUS ne conserve ni identifiants URI, ni chemin, paramètres ou fragment.

Les [clefs de stratégie du pare-feu](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpfas/2100c552-7f37-4a7f-9fa0-2a864ab87212) comprennent `PrivateProfile` et l’ancienne `StandardProfile`. Une contradiction entre elles reste inconnue ; une lecture refusée ne cède pas la priorité à une valeur locale. Connexions non lues et absence de connexion sont distinguées. Les résumés, faits, exports et sondes ne présentent plus un profil inconnu comme activé ; il s’agit d’une configuration déclarée, pas d’un test effectif du filtrage réseau.

Six tests écrits et compilés couvrent le contrat fermé, les états absents/refusés/inconnus, l’arrêt après rejet d’identité, les limites, les configurations contradictoires et les données expurgées. Debug/Release sans erreur ni avertissement dans la VM ; exécution des tests et recette réelle encore à faire en fin de développement.

## 12. Inventaire logiciel par registre (23/10/2026)

Le collecteur lit les deux vues Uninstall et, sur option, les ruches HKU déjà chargées dont le nom est un SID de profil. Aucune ruche n’est montée. Le plafond de 400 clés est partagé entre les deux vues pour la machine, puis entre tous les profils pour la portée utilisateur. Chaque clé conserve sa ligne, sa vue et son SID ; les homonymes ne sont pas fusionnés. Les informations déclarées suivent le [contrat des valeurs Uninstall](https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key).

Le filtrage des mises à jour examine `SystemComponent`, `ReleaseType` et `ParentKeyName` dans les deux vues. Un filtre illisible rend la portée partielle et n’inclut pas arbitrairement l’entrée. Une date invalide reste inconnue, la taille DWORD est convertie en octets sur 64 bits. Pour une commande de désinstallation, seul l’exécutable est conservé ; aucun argument potentiellement secret et aucune exécution. Les métadonnées détaillées ne sont pas lues par l’inventaire rapide.

Une connexion StdRegProv est détenue seulement pendant le relevé logiciel, sur son worker et avec le compte choisi ; elle est libérée après le retour réel de la dernière lecture. Les délais par appel restent inclus dans le budget total de 130 s, ou 200 s avec profils. Une interruption conserve les observations déjà publiées. Refus, vue absente, lecture partielle et zéro logiciel sont distincts. SCCM et Appx restent à raccorder ; une option Store demandée indique explicitement son indisponibilité actuelle.

## 13. Transport CIM WinRM natif (23/10/2026)

`CimSession` sait sélectionner DCOM ou WinRM sans repli implicite. WinRM utilise le composant Windows `WSMan.Automation`, le port 5985 et Kerberos explicitement, avec chiffrement des messages conservé. Une adresse IP est refusée avant contact. Aucun TrustedHosts, Basic, CredSSP, contournement de certificat ou changement du poste. Le secret explicite passe comme BSTR natif temporaire effacé après affectation, sans chaîne de mot de passe managée. La connexion et les options COM restent détenues par le worker jusqu’à sa fin réelle, même après abandon de l’attente.

Le SELECT conserve la garde WQL, les projections et les plafonds du chemin DCOM. Le registre admet seulement les quatre méthodes de lecture déjà fermées ; les options d’architecture sont exigées dans la requête. Les délais de chaque appel sont réduits au temps restant. Un refus WinRM interdit d’autres contacts de cette session ; les codes d’authentification sont distingués des droits insuffisants. Les messages d’erreur fournis par le serveur ne sont pas recopiés.

XML : identité de classe/espace vérifiée, propriétés non demandées écartées, valeurs scalaires/tableaux/nil conservés, objets imbriqués et DTD refusés, résolution externe désactivée et tailles bornées. Les cinq tests de garde/décodage sont compilés seulement. Le fonctionnement COM, le passage du compte et les options du fournisseur doivent encore être qualifiés dans la VM en recette finale. Le réglage de Poste, Appx et les autres gestes WinRM restent à raccorder.

Références : [énumération WinRM](https://learn.microsoft.com/en-us/windows/win32/winrm/enumerating-or-listing-all-instances-of-a-resource), [constantes de session](https://learn.microsoft.com/en-us/windows/win32/winrm/session-constants), [chiffrement et options](https://learn.microsoft.com/en-us/windows/win32/winrm/other-session-constants), [déclarations d’interopérabilité Microsoft](https://github.com/PowerShell/PowerShell/blob/master/src/Microsoft.WSMan.Management/Interop.cs).

## 14. Sources Store et SCCM (23/10/2026)

L’option Store lit `Get-AppxPackage -AllUsers` via un shell WinRM dédié au relevé, sous le même compte Kerberos. Script fermé sans entrée de l’utilisateur, PowerShell Windows sans profil, plafond de 2 000 paquets et 1 Mio, métadonnées explicitement projetées. Nom du poste, identifiant du shell et identifiant de commande sont contrôlés avant publication. Délai de 60 s inclus dans le budget logiciel, dont 2 s réservées à la fermeture. Une attente de sortie poursuit la même commande, sans la relancer. L’arrêt ferme seulement ce shell ; création sans réponse ou fermeture non confirmée sont dites, sans deuxième création. Une durée de vie du shell est demandée au serveur. Aucun bureau, service ni tâche planifiée n’est arrêté.

Si les registres machine ont échoué sans fournir d’entrée, une requête bornée lit le fournisseur SCCM historique de Domenia 1, `Win32Reg_AddRemovePrograms` dans `root\cimv2`. La précédente mention de `CCM_InstalledProduct` dans la table était erronée : ce n’est pas le fournisseur utilisé par D1. SCCM reste un inventaire déclaré, à fraîcheur et architecture inconnues, et ne rend pas complet un registre refusé. Avec les mises à jour masquées, le nom/version de chaque `ProdID` et ses indicateurs sont contrôlés dans les deux vues du registre ; une ambiguïté ou un filtre illisible écarte l’entrée et le signale. L’inventaire ne touche jamais au fournisseur MSI.

Sept tests supplémentaires écrits et compilés seulement couvrent le cycle du shell, les sorties étrangères, les interruptions, les pertes de réponse, les plafonds, les options et le filtrage SCCM. Les comportements natifs COM, le shell et l’identité effective restent à qualifier dans la VM à la recette finale.

Références : [création d’un shell](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wsmv/593f3ed0-0c7a-4158-a4be-0b429b597e31), [réception et délai de sortie](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wsmv/50cc2c38-e094-4d59-aec2-39e09f314862), [fournisseur SCCM et effets du fournisseur MSI](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/support/windows-server/admin-development/windows-installer-reconfigured-all-applications.md).

## 15. Defender et version Windows déclarée (23/10/2026)

Le relevé antivirus lit `MSFT_MpComputerStatus` indépendamment de `SecurityCenter2`, notamment sur les serveurs. Les protections, âges et version proviennent des propriétés déclarées ; le mode est lu séparément pour conserver le relevé principal lorsqu’une ancienne classe ne l’expose pas. Les booléens inconnus restent inconnus, 65535 jours est présenté comme « jamais », et aucune analyse en cours n’est déduite d’anciennes dates. Un mode passif ne prouve pas à lui seul qu’un autre antivirus est présent. Les valeurs sont visibles dans le tableau de bord, les sondes et la grille/export d’inventaire.

L’inventaire rapide/complet ajoute UBR et DisplayVersion depuis le registre Windows : révision zéro conservée, version déclarée distincte du build. Ces deux lectures ne sont pas ajoutées au relevé court de recherche. Trois tests ajoutés et compilés seulement ; qualification native en recette finale.

Référence : [propriétés et sentinelles MSFT_MpComputerStatus](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/defender/msft-mpcomputerstatus).


## 16. Membres locaux, services, certificats et tâches (23/10/2026)

Le groupe Administrateurs est résolu par son SID intégré `S-1-5-32-544` avec `LocalAccount=True`, après contrôle du nom et du rôle du poste. Un contrôleur de domaine ou un rôle inconnu n’entraîne aucune énumération de membres. Les membres directs passent par NetAPI/RPC, sous le même compte sélectionné, sans développement des groupes du domaine. Plafond affiché de 500 membres ; refus d’authentification transmis à la session commune. Le worker garde seul son jeton et ses tampons jusqu’au retour natif. Si NetAPI demande une suite, l’énumération est drainée même après arrêt de l’attente pour libérer sa ressource RPC ; aucun nouveau relevé n’est lancé. Le rapport nomme ce transport distinct.

La lecture détaillée des services ajoute `DependOnService` et `DependOnGroup` depuis le registre dans le budget commun de 90 s. Les groupes de chargement gardent leur préfixe `+`. Refus, liste tronquée et anciens caches sans preuve donnent des dépendances inconnues, jamais « aucune » ; le graphe inverse signale son incomplétude. Le relevé rapide ne multiplie pas les appels de dépendances. Le démarrage différé inconnu reste visible comme tel.

En WinRM sélectionné, deux scripts fixes ajoutent les métadonnées du magasin `Cert:\LocalMachine\My` (512 certificats, 15 s) et les états/dates/résultats des tâches (1 000, 30 s). Les budgets incluent 2 s de fermeture du seul shell créé ; identité, format, dates UTC, tailles et champs projetés sont contrôlés. Aucun paramètre ni fragment de code n’est reçu de l’interface. Clés privées et actions de tâche ne sont jamais exportées. Les certificats expirés restent dans le bilan ; une date sans fuseau, un code manquant ou une lecture refusée ne devient pas un succès. Le chemin DCOM garde sa projection des définitions de tâches et signale les détails indisponibles, sans ouvrir implicitement WinRM. Une fermeture incertaine ne transforme pas un refus de la source en données exploitables, y compris pour Appx.

Six tests supplémentaires écrits et compilés seulement ; recette native des lectures RPC/WinRM à effectuer en fin de développement.

Références : [NetLocalGroupGetMembers et fin d’énumération RPC](https://learn.microsoft.com/en-us/windows/win32/api/lmaccess/nf-lmaccess-netlocalgroupgetmembers), [fournisseur de certificats Windows](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/about/about_certificate_provider), [état d’exécution des tâches](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/get-scheduledtaskinfo).


## 17. Configuration des lectures et des outils (23/10/2026)

`IPosteSettingsReader` lit localement `Domenia.config.json` au premier usage, hors constructeur et hors thread UI, avec plafond de 1 Mo. Une erreur d’accès temporaire n’est pas conservée. Aucun contenu de fichier ni champ étranger n’est retenu ; clés ambiguës (même avec casse différente), JSON trop profond et types invalides sont signalés. Les valeurs absentes conservent les défauts D1.

Le contexte de compte transmet désormais la sélection WinRM/DCOM et `Remote.UseCim` aux relevés Fiche, Rechercher, inventaire léger Accueil et sondes du parc, ainsi qu’au repli CIM des sessions. `Remote.UseRemoteRegistry=false` bloque StdRegProv avant contact. Désactiver CIM empêche aussi les shells d’inventaire ; aucun autre transport n’est lancé implicitement pour compenser ce choix. Les autres options de détection/repli sont lues pour le raccordement de Poste et ne donnent aucune autorisation d’intervention par elles-mêmes.

Le redémarrage garde un délai de 60 à 3 600 s ; le timeout TCP, 200 à 5 000 ms. Le réveil exige `Features.WakeOnLan=true` et, dans V2, une liste explicite `WakeOnLan.AllowedNetworks` (128 réseaux IPv4 canoniques au plus, /8 à /30). Un réseau invalide ou non aligné n’est pas élargi ; activer le réveil sans périmètre ne permet aucun envoi. Les chemins et empreintes de suite utilisent les clés réelles D1 `Suite.PestoPath`, `Suite.PestoSha256`, `Suite.FilProPath`, `Suite.FilProSha256`. Chemin absolu d’exécutable et SHA-256 doivent tous deux être déclarés ; le lanceur reste responsable de la vérification réelle au clic.

Six tests de configuration et de blocage avant contact ajoutés et compilés seulement. Les options de la console Poste seront exposées lors de son raccordement complet ; aucune recette native revendiquée à ce stade.


## 18. Socle local et identité du poste (23/10/2026)

La liste, l’ouverture de console, les inventaires/logiciels conservés et la recherche de comptes/groupes n’effectuent aucun contact LDAP ni machine. L’inventaire doit appartenir au GUID et dater d’après la création de l’objet. Son nom Windows est comparé au compte machine et au DNS cohérents : renommer le CN seul ne change pas Windows et ne doit pas invalider ce relevé. La même règle est partagée avec Fiche, Rechercher et les sondes du parc.

Le site n’est plus deviné à partir de l’OU. L’absence de métadonnées LAPS ne prouve pas l’absence de LAPS. Le gestionnaire déclaré et un nom de console observé restent des indices distincts ; aucun GUID utilisateur n’est déduit du seul nom. La recherche d’un compte refuse une autorité étrangère et les ambiguïtés. Les associations D1 doivent encore être qualifiées et raccordées ; elles ne sont pas présentées comme absentes.

Quatre tests ajoutés et compilés seulement. Le lecteur réel reste hors découverte automatique tant que le contrat réseau complet n’est pas implémenté ; aucune promotion du catalogue à ce stade.


## 19. Premières lectures réseau de la console (23/10/2026)

Chaque geste relit le compte ordinateur par LDAP et compare son GUID à celui de la console avant tout contact machine. Un compte recréé sous le même DN, un compte machine absent ou un DNS incohérent sont refusés. Le mapper ne fabrique plus un sAMAccountName depuis le CN. Le compte de la cascade et les réglages sont conservés pendant le relevé ; un changement de session invalide sa publication.

Ping : un écho ICMP d’une seconde, présence enregistrée avant affichage ; erreur, silence et réponse sont distincts. Le silence ICMP n’empêche pas la lecture CIM explicitement demandée par l’état courant. Inventaires rapide/complet : budgets du collecteur, résultat partiel conservé et sauvegardé après arrêt si son identité est confirmée. Un contenu dont le nom Windows diffère est écarté ; une identité non lue ne publie que le rapport d’accès, sans données attribuées.

Logiciels : portées réelles du collecteur, rapport de refus et résultat de session conservé. Services et état courant ne remplacent pas l’inventaire détaillé. Services partiels : aucun profil complet ni absence inventée. Processus : identité minimale et nombre de processeurs logiques lus avant les deux échantillons ; sans date de création, le PID ne prouve pas la continuité du processus. Une mesure inexistante reste inconnue, pas à 0 %. Les sessions utilisent WTS, puis le repli CIM non intrusif déjà documenté dans le budget commun de cinq secondes, sous le même compte.

Six tests de frontière et de projection écrits et compilés seulement. Le lecteur complet n’est pas encore exposé : événements, diagnostics, secrets, associations, sondes et repli avec autorisation restent à raccorder. Recette native et suites de tests prévues en fin de développement.


## 20. Événements par préréglage (23/10/2026)

La lecture réelle vérifie d’abord l’identité Windows, puis applique le préréglage compilé, ses journaux, fournisseurs et identifiants, la fenêtre UTC de 1 à 720 heures et le plafond de 1 à 200 événements. Aucun code ni filtre libre ne vient de l’interface. Les messages sont aplatis et limités à 500 caractères ; aucune structure XML brute n’est exportée. L’émetteur est demandé explicitement pour distinguer poste et événement général. Le CN d’affichage n’est pas utilisé comme nom Windows pour cette attribution.

WinRM utilise le shell fermé existant et Get-WinEvent avec filtres à la source, une sentinelle et un rapport par journal ; GroupPolicy Operational est inclus. L’absence de correspondance est distincte d’un refus. Identité du shell, format, journaux distincts, nombres, UTC et volume JSON sont contrôlés avant publication. Un élément hors sélection rend le bilan incomplet. DCOM utilise Win32_NTLogEvent pour System et Application ; les journaux opérationnels demandent WinRM et restent explicitement non lus lorsque ce transport n’est pas sélectionné. Aucun changement implicite de transport.

Budget de 30 s pour la collecte, fermeture ciblée incluse dans le budget du shell. Les événements déjà reçus sont conservés si la suite est arrêtée ; un plafond, un journal non lu ou une fermeture incertaine ne prouve pas l’absence d’événements. Un refus ne devient pas une lecture partielle exploitable au seul motif que la fermeture n’est pas confirmée. Cinq tests ajoutés et compilés seulement ; qualification dans la VM à effectuer lors de la recette finale.

Référence : [Get-WinEvent et ses filtres Windows PowerShell](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent?view=powershell-5.1).


## 21. Diagnostic rapide et triage réels (23/10/2026)

Le diagnostic rapide borne l’ensemble du geste à vingt secondes, vérification de l’objet AD comprise. Les trois connexions TCP (135, 445, 5985) sont parallèles, sans données applicatives, et bornées au timeout configuré ou deux secondes. Une ouverture TCP ne prouve ni un protocole fonctionnel ni un droit. Une interruption garde le port inconnu ; silence et fermeture ne prouvent pas que Windows est arrêté.

Quatre requêtes CIM suffisent : identité Windows, OS/dernier démarrage en une lecture, volume C: exact, quatre services de gestion. Aucun inventaire complet, registre, logiciel, shell ou repli intrusif. Le nom de compte Windows est confirmé avant affichage. Volume dupliqué/inattendu, état de service absent et liste partielle sont signalés ; un refus n’invente pas quatre services non installés. Le résumé ne peut plus être complet au seul motif que chaque source partielle a fourni une valeur.

Le triage de lenteur utilise le relevé court de système, mémoire, volumes, CPU et deux échantillons de processus. Les autres sources restent non lues. Une liste de processus partielle ne donne pas une charge totale. Ce geste ne remplace pas le dernier inventaire détaillé. Les événements dont le message est vide conservent leurs métadonnées au lieu d’être écartés.

Quatre tests ajoutés et une assertion d’événement complétée, compilés seulement ; qualification native toujours prévue à la recette finale.


## 22. Explorateur WMI réel (23/10/2026)

Trois chemins de métadonnées fermés lisent les espaces directs, les définitions de classes et le schéma d’une classe. DCOM utilise les métadonnées WMI et Get de ManagementClass, jamais GetInstances pour le schéma. WinRM utilise un script fermé Get-CimClass ; seuls les noms validés entrent comme paramètres. Aucune valeur de propriété ni valeur arbitraire de qualificatif n’est lue dans le schéma : nom, type, clé et noms des qualificatifs seulement. Définitions liées au nom du poste, à l’espace et à la classe, JSON borné, listes plafonnées à 256 espaces, 4 096 classes et 512 propriétés. Les définitions ambiguës sont écartées.

Avant les contacts, le SELECT demandé est validé par la grammaire commune, incluant MSI, secrets et énumérations générales de comptes. La requête réelle projette les colonnes non sensibles du schéma, avec priorité aux clés et au filtre ; aucune étoile n’est envoyée. Plafonds : 64 propriétés, 500 lignes, 2 048 caractères par valeur et 2 Mio affichables ; les limites sont annoncées dans le résultat. CommandLine, Command, arguments et désinstallation sont exclus de cette projection automatique ; un filtre sur ces valeurs est refusé. Objets imbriqués exclus, tableaux bornés. Les lignes reçues sont publiées au fil de la lecture pour être conservées après arrêt.

La couche CIM borne aussi les valeurs brutes : 128 propriétés, 32 768 caractères par chaîne, 2 048 éléments scalaires par tableau et 8 Mio par lecture. Une première valeur hors limites produit un résultat partiel, jamais une absence. DCOM ne copie que les propriétés demandées, comme le transport WinRM. Les gardes du chemin général restent inchangées pour les classes système : seules les opérations internes de métadonnées peuvent interroger __Namespace ou meta_class.

Les gestes complets sont limités à 30 s pour les listes et 45 s pour une requête, vérification AD comprise. Les enfants d’un espace restent inconnus jusqu’à leur ouverture, sans exploration récursive implicite. Le statut de lecture des classes est affiché, les types natifs conservent le rendu de date, les qualificatifs sont consultables et une réponse vide refusée/interrompue s’intitule « Lecture non concluante ».

Six tests ajoutés et compilés seulement. Les API natives DCOM/WinRM et le parcours visuel seront vérifiés lors de la recette finale. Références : [métadonnées WMI](https://learn.microsoft.com/en-us/windows/win32/wmisdk/retrieving-a-class), [Get-CimClass](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-cimclass), [énumération des espaces CIM](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance).


## 23. Dernière connexion par contrôleur (23/10/2026)

La lecture relit le GUID de l’objet ordinateur, puis recherche ce GUID exact sur chaque contrôleur connu, avec l’identité de la connexion AD. Elle ne contacte pas Windows : une absence de DNS du poste ne bloque donc pas son historique AD. Au plus cinquante contrôleurs, quatre lectures simultanées et cinq secondes par contrôleur. Les contrôleurs au-delà de la limite restent dans le dénominateur de couverture.

Une valeur zéro signifie seulement qu’aucune connexion n’est enregistrée sur ce contrôleur. Attribut absent ou illisible, date antérieure au compte ou future, objet absent, identité différente et contrôleur non lu ne donnent pas une absence de connexion. La date maximale ne porte que sur les lectures concluantes ; un contrôleur non lu peut en connaître une plus récente. lastLogonTimestamp reste une estimation répliquée, sans preuve de présence actuelle.

Un rejet d’authentification suspend les contacts en attente et est enregistré dans l’état d’accès. Aucun autre compte n’est essayé. L’arrêt conserve les dates déjà reçues, et les autres lignes restent inconnues. Un changement de session invalide la publication. Quatre tests écrits et compilés seulement ; recette native prévue en fin de développement.


## 24. Sondes détaillées et historique local (23/10/2026)

La sélection est validée intégralement avant LDAP. Une lecture de l’identité Windows précède uniquement les requêtes des sondes choisies ; propriétés et filtres proviennent du catalogue compilé. Le budget commun est de 60 secondes, huit secondes par sonde, sans repli implicite. Chaque sonde conserve jusqu’à 500 lignes, 192 Kio de cellules JSON primitives, 2 048 caractères par texte et 256 éléments scalaires par tableau. Une valeur hors limite reste inconnue et la réponse partielle ; aucun tronquage d’identifiant n’est présenté comme une identité complète. Les tableaux EDID et réseau restent des tableaux.

Les colonnes reçues sont enregistrées dans le cache SQLite, séparées de l’inventaire complet et liées au GUID de l’ordinateur. La transaction fusionne chaque sonde selon sa date : deux relevés de sondes différentes ne s’écrasent pas. Dernière réussite complète, dernière tentative et date des données sont distinctes. Refus et arrêt n’effacent pas le dernier contenu daté. Le détail le laisse consultable avec sa provenance, sans le réinterpréter comme une mesure actuelle réussie. Une sélection partielle conserve ses valeurs brutes et n’invente pas un bilan complet à partir des sources non lues. Aucun ancien identifiant de batterie, numéro de processeur ou état actif d’écran n’est fabriqué dans le détail.

Les interprétations sont calculées localement depuis ces colonnes, sans requêtes supplémentaires. Les compteurs de disque se joignent par identité unique. Les capacités de batterie du pilote se joignent par InstanceName exact, jamais par position à une charge Win32_Battery non identifiée. Paramètres du pare-feu et sécurité matérielle restent des déclarations, sans preuve d’une stratégie effective ou d’un Secure Boot actif. Une liste de services incomplète ne donne pas de conformité complète.

L’historique du volume C: conserve un point valide toutes les six heures, au plus 60 points sur 400 jours ; une tentative en échec ne crée aucun point. Ce volume n’est pas supposé être le volume système. L’historique EDID conserve 20 changements entre ensembles complets, insensible à l’ordre des lignes ; une lecture partielle ne devient pas la référence de comparaison. Les bases D1 existantes restent préservées ; leur ancien historique non qualifié n’est pas inventé à partir du nouveau relevé.

Neuf tests ajoutés et compilés seulement, couvrant sélection, identité, arrêt, limites, projection, conservation après refus, historique, fusion SQLite et raccordement AD/local. Qualification native et exécution des suites à la recette finale.


## 25. Diagnostic complet réel (23/10/2026)

Le budget de 45 secondes commence avant la vérification AD. DNS (4 s), un écho ICMP et les ports 135/445/3389/5985/5986 sont lus indépendamment ; le silence ICMP ne bloque pas CIM. Une ouverture TCP prouve seulement l’acceptation d’une connexion. L’inventaire conservé n’est pas remplacé ; seul le résultat ICMP daté rejoint la présence du parc.

CIM confirme le nom Windows avant le système et ses autres sources. Le volume système vient de SystemDrive, validé comme lettre de lecteur : sans cette information, aucun C: n’est supposé. CBS, Windows Update et les renommages en attente sont lus séparément ; absence confirmée, indicateur possible et source non lue restent distincts. Le contrôle rapide conserve son contrat distinct sur C:.

Trois contrôles authentifiés emploient le même compte sélectionné : Identify WS-Management Kerberos (6 s), ouverture de la racine C$ avec le droit de lister et OPEN_EXISTING (6 s), puis Connect/GetFolder sur la racine du planificateur (8 s). Aucun fichier énuméré ou créé, aucune tâche créée ou exécutée. Une lecture réussie du planificateur ne prouve pas le droit de créer une tâche. Le mot de passe de Connect passe par un BSTR natif temporaire, effacé après retour, sans chaîne managée supplémentaire. Les appels natifs possèdent leur copie de compte jusqu’à leur fin effective même si l’interface cesse d’attendre.

Un rejet d’authentification ou un nom Windows étranger suspend les autres accès authentifiés. Arrêt, budget et saturation des workers conservent les contrôles reçus. Les résultats non concluants disposent d’un compteur et d’un rendu distincts : aucune réponse du poste n’est déduite du DNS seul, aucun port ignoré n’est considéré fermé, et un délai WinRM ne prouve pas une configuration absente. Les contrôles de repli respectent la configuration ; aucun PsExec non approuvé n’est lancé. Le repli de collecte avec création d’artefacts reste un circuit séparé, encore à raccorder à son autorisation unique.

Sept tests écrits et compilés seulement. Le test natif local du planificateur, les appels SMB/WinRM et le parcours visuel seront exécutés lors de la recette finale. Références : [ouverture Windows en lecture seule](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew), [connexion au planificateur](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/nf-taskschd-itaskservice-connect), [arguments IDispatch en ordre inverse](https://learn.microsoft.com/en-us/windows/win32/api/oaidl/nf-oaidl-idispatch-invoke), [contrôle Identify WS-Management](https://learn.microsoft.com/en-us/windows/win32/winrm/detecting-whether-a-remote-computer-supports-ws-management-protocol).

## 26. Métadonnées LAPS, BitLocker et durée de vie des secrets (23/10/2026)

LAPS lit exclusivement les deux attributs d’expiration après validation du GUID ordinateur. Une date visible ne prouve ni publication du mot de passe ni droit de lecture. Le bouton de révélation propose un geste distinct sans prélecture secrète. Une absence d’attribut reste non concluante. Budget global de vingt secondes ; aucune donnée confidentielle dans cette vue.

La liste BitLocker demande les GUID, noms et dates des objets `msFVE-RecoveryInformation` directement sous le poste. Une 257e ligne détecte le dépassement de la limite affichée de 256. Les identités illisibles ou dupliquées sont écartées et la liste devient explicitement partielle. Un GUID de volume reste un identifiant, jamais une lettre C: supposée. Une liste vide avec ce compte ne prouve pas l’absence de clés.

La révélation valide le parent et le GUID de récupération complet avant toute demande de mot de passe, puis scelle la recherche à l’objectGUID de l’objet récupération. Identifiant, type, DN enfant direct et parent ordinateur sont revérifiés ; une recréation écarte le résultat. Une seule valeur structurée en huit blocs est remise à la fenêtre native, sans cache ni export. Budget global de vingt-cinq secondes, recherches bornées et compte LDAP commun au geste sans repli.

`SecretReading` possède désormais un tampon effaçable, libéré à la fermeture, à l’échéance ou après échec d’ouverture. Le pont transfère la propriété à la fenêtre seulement en cas de succès. Le propriétaire ne permet plus copie ni révélation après libération ; ses métadonnées restent utilisables. Les copies de présentation exigées par WinForms et le presse-papiers sont des chaînes managées : vider les contrôles et abandonner ces références n’est pas une garantie d’effacement immédiat de toutes les copies du runtime.

Sept tests de frontières et de propriété écrits et compilés seulement. Debug/Release sans avertissement. Révélation LAPS réelle, autre compte, index et recette native restent en cours ; aucun secret du domaine réel n’a été demandé.
