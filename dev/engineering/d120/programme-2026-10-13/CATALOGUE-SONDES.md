# Catalogue de collecte — définition et qualification

État du développement au 13 octobre 2026. Les sources ci-dessous ont été consultées. **La qualification de ces nouveaux fournisseurs Windows est à réaliser en fin de développement.** Aucun succès de lecture réseau ni compatibilité matérielle ne sont déduits de la documentation.

## Circuit et autorité

`Domenia-ProbeCatalog.json` décrit 23 nouvelles projections de propriétés documentées. `Domenia-ProbeCatalog.Model.ps1` valide les identifiants, classes, champs et références ; `Domenia-Probes.Model.ps1` les joint au catalogue existant. L’atelier et le sélecteur de widgets consomment cette même définition. Les objets collectés suivent le circuit commun : lecture explicite, écriture SQLite confirmée, puis consultation des données enregistrées. Ajouter un widget ne lance pas automatiquement une collecte.

Une sonde n’est pas une action : aucune méthode WMI, aucun appel de modification, aucun `Win32_Product`, aucun mot de passe, argument de commande ou clé de récupération n’est ajouté. Les tableaux de propriétés et instances détaillées restent typés. Le budget des détails est annoncé par le collecteur, avec nombre lu, nombre conservé et cause d’une éventuelle limite ; un détail tronqué n’est pas présenté comme complet.

Chaque entrée expose description, droits, compatibilité, signification d’un résultat inconnu, limites, références primaires, champs et unités. `ProviderQualification` reste « À qualifier sous Windows ». Les propriétés historiques sans type documentaire vérifié gardent une description conservatrice, sans type numérique inventé.

## Projections ajoutées

| Famille | Projections | Interprétation et source |
|---|---|---|
| Mémoire | `hw.memorymodules`, `hw.memoryarrays` | Barrettes et groupes mémoire. Capacité des barrettes en octets ; `MaxCapacityEx` en Ko, zéro inconnu. [PhysicalMemory](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-physicalmemory), [PhysicalMemoryArray](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-physicalmemoryarray). |
| Volumes | `disk.volumes` | Volumes fixes avec lettre, capacité et espace libre datés. Aucune prévision sans historique. [LogicalDisk](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-logicaldisk). |
| Stockage physique | `disk.physical`, `disk.reliability` | États et compteurs rapportés par le pilote. Leur absence n’est pas un bon état. [PhysicalDisk](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-physicaldisk), [StorageReliabilityCounter](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-storagereliabilitycounter). |
| Batteries | `hw.batteries` | Capacités zéro = information non prise en charge ; la classe ne fournit pas le nombre de cycles. [Battery](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-battery). |
| BIOS | `hw.biosdetails` | Version et date déclarées ; référence approuvée nécessaire avant un jugement de conformité. [BIOS](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-bios). |
| Processeurs | `hw.processors` | Tous les sockets, capacités et cœurs ; une VM décrit le matériel présenté à l’invité. [Processor](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-processor). |
| Écrans | `hw.monitors` | Codes EDID conservés en tableaux ; absence d’EDID explicitée. [WmiMonitorID](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorid). |
| Réseau | `net.interfaces`, `net.configurations` | Physique/virtuel, état, IP, DNS, passerelles et DHCP. Les listes sont conservées ; aucune preuve de connectivité n’est déduite de leur configuration. [NetworkAdapter](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-networkadapter), [NetworkAdapterConfiguration](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-networkadapterconfiguration). |
| Périphériques | `soft.printerdetails`, `hw.deviceerrors` | État du fournisseur, avec limites de session des imprimantes. [Printer](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-printer), [PnPEntity](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-pnpentity). |
| Services | `soft.servicedetails` | État, mode et PID. Un service automatique arrêté n’est pas automatiquement en panne. [Service](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-service). |
| Correctifs | `soft.hotfixdetails` | Vue CBS seulement, sans conclure à une conformité globale des mises à jour. [QuickFixEngineering](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-quickfixengineering). |
| Processus | `soft.processdetails` | Photographie mémoire/compteurs, sans arguments. Un taux CPU nécessite plusieurs échantillons. [Process](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process), [mesures de performance WMI](https://learn.microsoft.com/en-us/windows/win32/wmisdk/wmi-tasks--performance-monitoring). |
| Démarrage | `soft.scheduledtasks`, `soft.startupdetails` | Identité et état des tâches, emplacement des démarrages. Dernière exécution absente de la classe d’énumération, aucun argument lu. [MSFT_ScheduledTask, Microsoft](https://github.com/microsoft/wmi/blob/master/server23h2/root/microsoft/windows/taskscheduler/MSFT_ScheduledTask.go), [StartupCommand](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-startupcommand). |
| Defender | `sec.defenderdetails` | Déclarations du fournisseur Defender ; aucun jugement sur un antivirus tiers absent de cette source. [MpComputerStatus](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/defender/msft-mpcomputerstatus). |
| Pare-feu | `sec.firewallprofiles` | Paramètres retournés, sans prétendre au magasin effectif ni à l’origine GPO. [NetFirewallProfile](https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/wfascimprov/msft-netfirewallprofile). |
| VBS | `sec.deviceguard` | Capacité, configuration et exécution séparées. Disponibilité Secure Boot ne signifie pas activation. [DeviceGuard](https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity). |
| Protection disque et TPM | `sec.bitlockervolumes`, `sec.tpmdetails` | Conversion différente de protection ; valeurs à l’instanciation ; aucun secret ni méthode TPM. [EncryptableVolume](https://learn.microsoft.com/en-us/windows/win32/secprov/win32-encryptablevolume), [TPM](https://learn.microsoft.com/en-us/windows/win32/secprov/win32-tpm). |

## Corrections sémantiques

- La fausse projection `sec.uac` (compte d’instances du système d’exploitation) est retirée. Elle ne mesurait pas `EnableLUA`. Le réglage documenté est distinct : [EnableLUA](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-lua-settings-enablelua).
- `sec.bitlocker` décrit la **protection** de C:, pas le simple chiffrement.
- `soft.hotfixcount` est intitulé « Correctifs CBS visibles », sans promesse d’exhaustivité des mises à jour.
- `sec.shares` est intitulé « Partages de fichiers déclarés » ; son filtre `Type=0` ne justifie pas à lui seul une affirmation d’exclusion des partages administratifs.

## Couverture réelle des points 81–110

Les numéros de la feuille de route ne sont pas validés par la seule existence d’une sonde. Ce lot implémente les lectures CIM documentées et leur projection au catalogue. Restent à développer ou qualifier séparément :

- 81–89 : références BIOS approuvées, historique/tendance disque, usure calculée uniquement si capacités valides, cycles batterie/constructeur, comparaison de changements écran/station d’accueil et qualification matérielle.
- 90 : diagnostic DNS → ICMP → protocole, déjà distinct des valeurs de configuration réseau ; raccord du parcours d’assistance à contrôler.
- 91/93 : inventaire logiciel registre et indices de redémarrage existants ; ce catalogue ne les remplace pas par MSI ni une fausse classe universelle.
- 94–96 : dépendances de services, profil attendu, mesure CPU sur intervalle et dernière exécution d’une tâche demandent des lectures dédiées supplémentaires.
- 97–100 : couverture antivirus tiers, pare-feu effectif ActiveStore/origine, Secure Boot effectivement activé et certificats publics demandent d’autres fournisseurs de lecture ; aucun résultat simulé n’est exposé.
- 101–109 : attributs et diagnostics AD, groupes/délégations/GPO/LAPS/réplication sont des sources AD distinctes. Ils ne sont pas maquillés en sondes CIM de poste.
- 110 : les nouvelles informations sont utilisables dans l’atelier ; les parcours guidés d’assistance et leur collecte minimale restent à raccorder explicitement.

## Validation préparée

`Test-DomeniaProbeCatalog.ps1` prépare huit cas sans accès réseau : identifiants, types/tableaux/unités, exclusions sensibles, absence de fausses conclusions de sécurité, limites batteries/QFE/processus/tâches, payload projeté, compatibilité des anciennes sondes, parsing des modules. **Suite non exécutée pendant ce lot**, conformément à la consigne de reporter les tests à la fin du développement. Les fournisseurs, performances à 20 000 postes et rendu Windows restent à qualifier.
