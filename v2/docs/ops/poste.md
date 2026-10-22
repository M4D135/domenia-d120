# Écran « Poste » — opérations, écritures et mode annuaire

Console d’un poste de travail (Domenia 1 : onglets Poste, Tableau du poste, Administration, Sessions, Services,
Inventaire, Logiciels, Santé, WMI, Sécurité). Module `PosteOperations` (`Domenia.Bridge/Operations/PosteOperations*.cs`),
lecteur `IPosteReader` (`Domenia.Core/Screens/Poste/IPosteReader.cs`), lecteur simulé
`SimulatedPosteReader` (`Domenia.Simulation/Screens/Poste/`), écritures `Domenia.Core/Writes/Poste/` et
`Domenia.Simulation/Writes/Poste/`, page `web/js/pages/poste.js` et `web/js/pages/poste/*.js`, styles
`web/css/pages/poste.css`. Fonctions de Domenia 1 : `PST-001` à `PST-117` (`docs/features.json`), état dans
`docs/status/poste.json`.

## 1. Principes

- **Lecture seule par défaut.** `poste.open` ne lit que la base locale (fiche de l’annuaire, observations enregistrées,
  dernier inventaire) : aucune sonde réseau, aucun ping. Chaque lecture réseau part d’un geste (bouton, ouverture depuis
  la liste pour le seul ping de vérification, PST-051), vise **un seul poste**, est bornée dans le temps et peut être
  arrêtée (`poste.collect.stop`).
- **Jamais tout le domaine.** Les listes (`poste.list`, `poste.groups.search`) lisent la base locale de l’OU de travail,
  bornées (1 000 postes, 50 groupes). Aucune opération de l’écran ne parcourt le domaine.
- **Écritures par le circuit** (`docs/WRITES.md`) : `poste.<verbe>.plan` (une lecture) prépare un plan scellé, la page le
  montre, l’opérateur confirme (nom tapé pour les gestes dangereux), `write.execute` enregistre le reçu, envoie, relit.
  Rien n’est rejoué automatiquement ; un jeton ne sert qu’une fois.
- **Données honnêtes.** Chaque valeur est un `PosteFact` : valeur, état (`observed`, `estimated`, `refused`,
  `unavailable`, `unknown`), source, limite, conseil et date. Un refus ou une lecture partielle n’est jamais présenté
  comme « aucun » ; une mesure inconnue vaut `null`.
- **Aucun secret journalisé.** Les valeurs LAPS et BitLocker ne passent ni dans le journal des opérations, ni dans le
  journal technique, ni dans un reçu, ni dans un export (§ 6).

## 2. Routes de la page

`#/poste` affiche le choix d’un poste (liste de l’OU de travail, recherche locale, filtres, récents). `#/poste?dn=…` ou
`#/poste?nom=PC-PAR-0001` ouvre la console. Paramètres :

| Paramètre | Valeurs | Effet |
|---|---|---|
| `vue` | `ensemble`, `inventaire`, `diagnostic`, `releves`, `intervenir`, `secrets` | Vue ouverte. |
| `onglet` | noms de Domenia 1 (`TabWmi`, `TabSoftware`, `TabSessions`, `TabComputerServices`, `TabSecurity`…) et onglets internes (`materiel`, `logiciels`, `services`, `processus`, `sessions`, `reseau`, `rapide`, `lent`, `evenements`, `wmi`, `jonction`) | Vue et onglet (PST-048). |
| `panneau` | `postes`, `redemarrer`, `executer`, `groupe`, `deplacer`, `fiche` | Ouvre un panneau ; `executer` exige l’autorisation d’intervention. |
| `verifier` | `1` | Ouverture depuis la liste : un seul ping, puis le paramètre est retiré de l’adresse. |
| `essai` | `inventaire`, `logiciels`, `services`, `processus`, `sessions`, `diagnostic`, `rapide`, `lent`, `evenements`, `wmi`, `sondes`, `laps`, `bitlocker`, `live`, `detection`, `connexions` | **Simulation seulement** : lance une lecture pour les captures et les guides ; ignoré en mode annuaire. Jamais une révélation de secret. |

## 3. Opérations

Classe : celle du mode annuaire. En simulation, les lectures marquées « servie » sont admises (lectures en mémoire du
monde fictif, latence simulée) ; les plans sont `LocalRead` en simulation et `NetworkRead` en mode annuaire, comme
`accounts.unlock.plan`.

### 3.1 Lectures locales et état de session

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `poste.list` | `LocalRead` | `{ text?, limit? }` (texte ≤ 100, limite 1–1 000, 500 par défaut) | `PosteList` : postes de l’OU de travail avec présence, santé (niveau, points), utilisateur, système, site, dates. |
| `poste.open` | `LocalRead` | `{ dn }` | `PosteConsole` : `computer`, `header`, `association`, `live`, `inventory`, `board` (santé, fiches, ressources, disques, protection, activité, comptages, sections), `secrets` (résumé non secret), `consent`, `options`, `notes`. |
| `poste.software.cached` | `LocalRead` | `{ dn }` | `SoftwareResult` tiré du dernier inventaire (PST-025). |
| `poste.readings` | `LocalRead` | `{ dn }` | `ReadingsResult` : 15 lectures interprétées, fraîcheur (récente < 3,5 j, vieillissante, périmée > 7 j), prévision de saturation, BIOS comparé à la référence du modèle. |
| `poste.probe.details` | `LocalRead` | `{ dn, probe, page? }` | Valeurs enregistrées d’une sonde (100 lignes par page), lecture interprétée et contrat de la sonde (PST-074). |
| `poste.commands` | `LocalRead` | `{ dn }` | `PosteCommands` : Enter-PSSession, Invoke-Command, mstsc, UNC, consoles MMC ; valeurs entre apostrophes, jamais de mot de passe. |
| `poste.suite.plan` | `LocalRead` | `{ dn, tool: pesto\|filpro }` | `{ tool, plan, launched: false, text }` : champs déclarés et validés seulement (PST-020). |
| `poste.groups.search` | `LocalRead` | `{ text? }` | Au plus 50 groupes (`{ dn, name }`) dont le nom contient le texte, sans accent ni casse. |
| `poste.collect.stop` | `Local` | `{ dn }` | Arrête le relevé en cours du poste (inventaire, diagnostic, sondes). |
| `poste.consent.grant` | `Local` | `{ dn, kind: intervention\|readFallback, minutes? }` (1–15, 5 par défaut) | `{ consent, history }`. Ne lance rien. |
| `poste.consent.revoke` | `Local` | `{ dn, kind }` | `{ removed, consent, history }`. |
| `poste.consent.history` | `Local` | `{}` | Autorisations accordées, retirées, expirées ou utilisées dans la session. |
| `poste.dsreg.analyze` | `Local` | `{ dn, text, collectedAs: endUser\|admin\|unknown, endUser? }` | `DsregAnalysis` (128 Kio au plus) : jonction, mode, SSO évaluable seulement pour un texte collecté sous l’utilisateur final (PST-033). |
| `poste.bios.reference` | `LocalWrite` | `{ dn, action: approve\|remove }` | Préférence locale `poste.biosReferences.<sha256 du domaine>` ; aucune action sur le poste (PST-080). |

### 3.2 Lectures réseau (servies en simulation)

| Opération | Arguments | Résultat, bornes |
|---|---|---|
| `poste.ping` | `{ dn }` | `PresenceReading` : un écho ICMP, enregistré avant d’être montré (PST-050). |
| `poste.live` | `{ dn }` | `PosteLive` : présence, dernier démarrage, utilisateur console, sessions. |
| `poste.inventory` | `{ dn, deep }` | `InventoryResult` : lignes traduites (valeur brute gardée), état par source, catégories. Rapide 55 s, complet 150 s. Événements `poste.inventory:progress`. |
| `poste.software` | `{ dn, perUser, store, updates }` | `SoftwareResult` : registre Uninstall 64/32 bits, SCCM, ruches des profils, Appx ; jamais `Win32_Product`. 130 s (200 s avec les profils). |
| `poste.services` | `{ dn }` | `ServicesResult` : 500 instances au plus, profil attendu (15 services), arrêts attendus. |
| `poste.processes` | `{ dn }` | `ProcessesResult` : deux lectures espacées, part du processeur mesurée. |
| `poste.events` | `{ dn, preset, hours?, max? }` | `EventsResult` : préréglages `Startup`, `Crash`, `Disk`, `Policy`, `Updates`, 1–720 h, 1–200 événements, bornes dites. |
| `poste.sessions` | `{ dn }` | `SessionsResult` (WTS) : lignes sans compte comptées, jamais listées. |
| `poste.restart.sessions` | `{ dn }` | `RestartSessions` : sessions lues avant un redémarrage ; une lecture impossible est dite, le redémarrage différé reste possible (PST-014). |
| `poste.diagnostic` | `{ dn }` | `DiagnosticResult` : DNS, ping, ports 135/445/3389/5985/5986, CIM, C$, WinRM, replis, système, disque ; couches et étape bloquante ; 45 s. Événements `poste.diagnostic:progress`. |
| `poste.quickDiag` | `{ dn }` | `QuickDiagResult` : cinq contrôles, 20 s annoncées, aucun repli (PST-004). |
| `poste.slow` | `{ dn }` | `SlowTriage` : pistes classées (mémoire, processeur mesuré, disques, redémarrage, démarrage automatique, journaux 72 h, lien réseau). |
| `poste.wmi.namespaces` | `{ dn, parent? }` | Espaces de noms (root et enfants directs). |
| `poste.wmi.classes` | `{ dn, ns }` | Classes, celles du fournisseur MSI marquées bloquées. |
| `poste.wmi.query` | `{ dn, ns, cls, where?, limit? }` | `WmiQueryResult` : `SELECT *` validé, 1–500 instances (25 par défaut), aucune méthode. Refus : `poste.queryRefused`. |
| `poste.probes.collect` | `{ dn }` | `ReadingsResult` : sondes du tableau relevées une fois, enregistrées, puis interprétées (PST-110). Événements `poste.probes.collect:progress`. |
| `poste.logonByDc` | `{ dn }` | `LogonActivity` : `lastLogon` sur chaque contrôleur (PST-114). |
| `poste.lastUser.detect` | `{ dn }` | `LastUserDetection` : association locale, CIM, LogonUI, WinRM, profils ; 25 s ; une association existante n’est jamais écrasée (PST-117). Événements `poste.lastUser.detect:progress`. |
| `poste.laps` | `{ dn }` | `LapsView` : métadonnées, sans valeur (PST-063). |
| `poste.laps.reveal` | `{ dn }` | `SecretReveal` (§ 6). |
| `poste.bitlocker.list` | `{ dn }` | `BitLockerList` : objets de récupération sous le poste (un niveau, 256 au plus), sans clé (PST-053). |
| `poste.bitlocker.reveal` | `{ dn, key }` | `SecretReveal` en huit blocs ; la clé doit être un enfant direct du poste (`poste.keyNotChild`). |
| `poste.wapt` | `{ dn }` | `WaptRecord` : connecteur en lecture seule ; « Constaté » seulement si récent et conforme au poste AD (PST-001). |

`poste.tool.open` (`{ dn, tool: rdp|c|compmgmt|eventvwr|services }`, `NetworkRead`, **non servie** en simulation) répond
`source.unavailable` dans cette version : l’ouverture d’un outil Windows passera par le lanceur du poste d’administration
(vague 3). La page propose la commande à copier.

### 3.3 Erreurs propres à l’écran

| Code | Cause |
|---|---|
| `poste.unknown` | Le DN ne désigne aucun poste (compte utilisateur, objet supprimé). |
| `poste.unreachable` | Le poste ne répond pas (aucune conclusion sur son état). |
| `poste.consentRequired` | Exécuter un programme sans autorisation d’intervention active sur ce poste. |
| `poste.refused` | Demande refusée par une règle (mode inconnu, message trop long, WinRM désactivé, valeur invalide). |
| `poste.queryRefused` | Requête WMI refusée (espace, classe, filtre, fournisseur MSI). |
| `poste.keyNotChild` | Clé BitLocker hors du poste ouvert. |
| `poste.cancelled` | Relevé arrêté par l’opérateur. |

## 4. Écritures (circuit `write.execute`)

| Plan | Arguments | Type (`Kind`) | Confirmation | Vérification |
|---|---|---|---|---|
| `poste.account.plan` | `{ dn, enable }` | `poste.accountState` | nom tapé pour désactiver | relecture de `userAccountControl` |
| `poste.profile.plan` | `{ dn, description?, location?, managedBy? }` | `poste.profile` | simple ; seuls les attributs modifiés partent | relecture des attributs |
| `poste.rename.plan` | `{ dn, name }` (1–15) | `poste.rename` | nom tapé ; le poste Windows n’est pas renommé | relecture par GUID |
| `poste.group.plan` | `{ dn, group, add }` | `poste.group` | simple (ajout), nom tapé (retrait d’un groupe protégé) | relecture de `member` |
| `poste.move.plan` | `{ dn, ou }` | `poste.move` | nom tapé | relecture par GUID |
| `poste.restart.plan` | `{ dn, mode: delayed\|now, minutes?, message? }` (1–60 min, message ≤ 400) | `poste.restart` | nom tapé pour « maintenant » | redémarrage programmé ou dernier démarrage |
| `poste.restartCancel.plan` | `{ dn }` | `poste.restartCancel` | simple | plus de redémarrage programmé |
| `poste.gpupdate.plan` | `{ dn }` | `poste.gpupdate` | simple ; WinRM requis | code de retour de gpupdate |
| `poste.service.plan` | `{ dn, name, action: start\|restart\|stop }` | `poste.service` | nom tapé pour redémarrer ou arrêter ; type de démarrage jamais modifié | relecture de l’état du service |
| `poste.run.plan` | `{ dn, mode: system\|interactive, command, arguments?, user?, elevated? }` | `poste.run` | autorisation d’intervention **et** nom tapé | envoi de la tâche seulement (l’exécution du programme n’est pas vérifiée) |
| `poste.wake.plan` | `{ dn }` | `poste.wake` | simple ; Wake-on-LAN activé, carte valide, sous-réseau autorisé | ping après le délai annoncé |

En simulation, les écritures annuaire s’appliquent à la surcouche en mémoire (`SimulatedDirectoryOverlay.UpdateComputer`,
`UpdateGroup`, ajoutés comme prévu par `WRITES.md`) et les actions distantes à l’état simulé du poste
(`PosteSimulation`) : redémarrage programmé visible dans les notes de la console, service relu, réveil enregistré.

## 5. Autorisations de session (`PosteSession`)

- **Intervention** (PST-010, PST-017) : 1 à 15 minutes, un seul poste, exigée par `poste.run.plan`. Le décompte s’affiche
  dans l’en-tête ; « Retirer » la lève tout de suite ; elle expire seule.
- **Lecture de repli** (PST-011, PST-023) : une seule lecture par PsExec puis tâche planifiée quand WMI et WinRM refusent,
  consommée une fois, distincte de l’intervention. Sans elle, une lecture rend « non lu » au lieu de basculer.
- L’historique (`poste.consent.history`) garde accordée, retirée, expirée, utilisée ; il vit dans la session seulement.

## 6. Secrets révélés : exception au § 1.2 de `OPERATIONS.md`

`OPERATIONS.md` § 1.2 interdit tout mot de passe ou clé dans une réponse. Les fonctions PST-055 à PST-058, PST-063 et
PST-064 de Domenia 1 révèlent pourtant **une** valeur sur un geste explicite. `poste.laps.reveal` et
`poste.bitlocker.reveal` renvoient donc la valeur (`value` pour LAPS, `blocks` seulement pour BitLocker), avec ces
garde-fous : un geste par valeur, une seule valeur affichée à la fois, 30 s d’affichage et une prolongation de 30 s,
effacement de la page à l’échéance ou au changement de vue, copie vidée du presse-papiers après 30 s, aucune trace dans
les journaux, les reçus, les exports ou le stockage. En simulation, les valeurs sont **fictives** et signalées comme telles.
**À valider** : amendement du § 1.2 de `OPERATIONS.md` (fichier partagé non modifié par ce lot). La protection du
presse-papiers côté hôte (vider seulement si la valeur n’a pas changé) reste à faire avec un pont hôte.

## 7. Simulation

Les données de chaque poste sont dérivées de façon déterministe de son GUID (`ScreenStream("poste").Fork(guid)`) :
modèle (six modèles, dont les noms de `SIMULATION.md`), mémoire et disque (cohérents avec `InventoryMeasure` de la base
locale), disque mécanique sur 7 % des fixes, usure élevée sur 2 %, BitLocker actif, suspendu ou absent, adresse IP par site
(10.10 à 10.50 /22), cause de lenteur, association (managedBy déclaré ou contradictoire, sinon utilisateur du site
observé ou historique, aucun pour 14 %), logiciels, démarrage automatique, services (WinRM arrêté sur 10 %, Spooler,
WSearch, Dnscache en panne çà et là), correctifs, historique des volumes, écrans, batterie, événements, tâches,
certificats ; antivirus refusé sur 3 %. Les postes qui ne répondent jamais au ping, les sondes en erreur et le ping filtré
(répond à WMI, jamais au ping) reprennent `World.Presence`. Lecture BitLocker refusée pour les postes de Marseille (refus
mémorisé). Options de simulation : Wake-on-LAN activé sur 10.0.0.0/8, WAPT fictif `https://wapt.example.local`, compte
d’exploitation `EXAMPLE\adm-j.martin`, Pesto et FILPRO non configurés.

## 8. Mode annuaire (vague 3)

### 8.1 Annuaire (LDAP, `Domenia.Ad`)

| Besoin | Requête | Attributs |
|---|---|---|
| Fiche du poste (`poste.open`, base) | Base sur le DN, contrôleur de la session | `name`, `cn`, `dNSHostName`, `sAMAccountName`, `objectSid`, `objectGUID`, `operatingSystem`, `operatingSystemVersion`, `description`, `location`, `managedBy`, `userAccountControl`, `whenCreated`, `whenChanged`, `pwdLastSet`, `lastLogonTimestamp`, `memberOf`, `msLAPS-PasswordExpirationTime`, `ms-Mcs-AdmPwdExpirationTime`, `primaryGroupID` |
| Liste (`poste.list`) | base locale de l’OU de travail (instantané du parc), aucune requête | — |
| LAPS, métadonnées | Base sur le DN | `msLAPS-PasswordExpirationTime`, `msLAPS-EncryptedPassword` (présence seulement, `attributeTypes` sans valeur), `ms-Mcs-AdmPwdExpirationTime` |
| LAPS, révélation | Base sur le DN, sur geste | `msLAPS-Password` ou `msLAPS-EncryptedPassword` (déchiffrement DPAPI-NG par l’API Windows), sinon `ms-Mcs-AdmPwd` |
| BitLocker, liste | OneLevel sous le DN, `(objectClass=msFVE-RecoveryInformation)`, 256 au plus | `name`, `msFVE-RecoveryGuid`, `msFVE-VolumeGuid`, `whenCreated` ; jamais `msFVE-RecoveryPassword` |
| BitLocker, révélation | Base sur le DN de la clé (enfant direct vérifié) | `msFVE-RecoveryPassword` |
| Connexions par contrôleur | Base sur le DN, sur **chaque** contrôleur du domaine (liste de la session), 5 s chacun | `lastLogon` |
| Groupes | base locale (instantané) ; en repli : sous la racine, `(&(objectCategory=group)(name=*texte*))`, 50 au plus | `distinguishedName`, `name` |
| Écritures | `Modify` (`userAccountControl`, `description`, `location`, `managedBy`, `member` du groupe), `ModifyDN` (renommage `cn` + `sAMAccountName`, déplacement `newSuperior`) | relecture par GUID après l’écriture |

### 8.2 Poste (WMI/CIM, WinRM, registre)

Transport : CIM sur WinRM (5985, Kerberos) quand `Remote.UseWinRM` est vrai, sinon CIM sur DCOM (135 puis ports
dynamiques) ; repli PsExec puis tâche planifiée seulement avec l’autorisation de lecture de repli. Une session CIM par
relevé, fermée à la fin ; chaque source a son propre délai et son propre état.

| Catégorie ou sonde | Classes et sources |
|---|---|
| Système, matériel | `Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_ComputerSystemProduct`, `Win32_BIOS`, `Win32_Processor`, `Win32_PhysicalMemory`, `Win32_PhysicalMemoryArray`, `Win32_SystemEnclosure` |
| Disques | `Win32_LogicalDisk` (`DriveType=3`), `MSFT_PhysicalDisk` et `MSFT_StorageReliabilityCounter` (`root\Microsoft\Windows\Storage`) |
| Sécurité du démarrage | `Win32_EncryptableVolume` (`root\CIMV2\Security\MicrosoftVolumeEncryption`), `Win32_Tpm` (`root\CIMV2\Security\MicrosoftTpm`), registre `SYSTEM\CurrentControlSet\Control\SecureBoot\State` |
| Réseau | `Win32_NetworkAdapter`, `Win32_NetworkAdapterConfiguration` (`IPEnabled=TRUE`), `MSFT_NetFirewallProfile` et `MSFT_NetConnectionProfile` (`root\StandardCimv2`), `MSFT_NetTCPConnection` (complet) |
| Protection | `AntiVirusProduct` (`root\SecurityCenter2`), `MSFT_MpComputerStatus` (`root\Microsoft\Windows\Defender`) |
| Mises à jour | `Win32_QuickFixEngineering`, registre `SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`, clés de redémarrage en attente (CBS, Windows Update, `PendingFileRenameOperations`) |
| Logiciels | `StdRegProv` : `Uninstall` 64 et 32 bits, ruches `HKU` des profils chargés (option), `CCM_InstalledProduct` (`root\ccm\cimodels`) si SCCM, Appx (option Store, par WinRM) ; jamais `Win32_Product` |
| Démarrage, tâches | `Win32_StartupCommand`, `MSFT_ScheduledTask` (`root\Microsoft\Windows\TaskScheduler`, complet) |
| Services | `Win32_Service` (500 au plus) ; écritures par `StartService`/`StopService` via WinRM, jamais `ChangeStartMode` |
| Processus | `Win32_PerfFormattedData_PerfProc_Process` lu deux fois, `Win32_Process` (chemin, propriétaire) |
| Périphériques | `Win32_PnPEntity` (`ConfigManagerErrorCode<>0`), `Win32_PnPSignedDriver`, `WmiMonitorID` et `WmiMonitorConnectionParams` (`root\wmi`), `Win32_Battery`, `BatteryFullChargedCapacity` (`root\wmi`), `Win32_Printer` |
| Sessions | API WTS (`WTSEnumerateSessions`, `WTSQuerySessionInformation`) ; repli `quser` par WinRM |
| Événements | `Get-WinEvent` filtré par préréglage (journal, fournisseurs, identifiants, fenêtre) |
| Certificats | magasin `Cert:\LocalMachine\My` par WinRM (complet) |
| Dernier utilisateur | association locale, `Win32_ComputerSystem.UserName`, registre `LogonUI\LastLoggedOnUser`, WinRM, `Win32_UserProfile` (`LastUseTime`) |
| Sondes (33) | classes de `ProbeCatalog` (`Domenia.Core/Screens/Poste/ProbeCatalog.cs`), propriétés et filtres du contrat de chaque sonde |

### 8.3 Budgets

| Lecture | Budget |
|---|---|
| Ping | 1 écho, 1 000 ms |
| État en direct | 10 s |
| Inventaire rapide / complet | 55 s / 150 s |
| Logiciels | 130 s, 200 s avec les profils |
| Services | 90 s |
| Processus | 2 lectures espacées de 1 s, 20 s |
| Événements | 30 s |
| Diagnostic complet / rapide | 45 s / 20 s |
| Détection du dernier utilisateur | 25 s |
| Sondes | 60 s pour l’ensemble |
| Connexions par contrôleur | 5 s par contrôleur |
| Révélation d’un secret | 15 s |

## 9. Décisions appliquées

- Fin de support Windows : **non retenue** (`DECISIONS.md`, « balec ») ; les règles de fin de support ne produisent aucun
  point d’attention.
- Thèmes : clair, sombre, contraste élevé ; animations en `transform`, `opacity`, `filter` ; « Animations réduites »
  respectée.
