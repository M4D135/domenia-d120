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
| `poste.export.save` | `LocalWrite` | `{ dn, kind, files: [{ part: lignes\|sources\|liste, csv }] }` (1 ou 2 parties, 8 Mio au plus) | `ExportResult` : fichier choisi par l’opérateur dans la boîte « Enregistrer sous » de Windows, nommé `Domenia-<poste>-<kind>-AAAAMMJJ-HHmm.csv`, la seconde partie à côté (`…-sources.csv`), UTF-8 avec BOM (PST-006, PST-039, PST-047). Sans hôte : `poste.hostUnavailable`, la page copie la liste. |

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
