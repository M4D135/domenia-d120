# Catalogue de collecte — définition et qualification

État du développement au 13 octobre 2026. Les sources ci-dessous ont été consultées. **La qualification de ces nouveaux fournisseurs Windows est à réaliser en fin de développement.** Aucun succès de lecture réseau ni compatibilité matérielle ne sont déduits de la documentation.

## Circuit et autorité

`Domenia-ProbeCatalog.json` décrit 31 projections de propriétés documentées (23 le 13 octobre, 8 ajoutées le 15 octobre). `Domenia-ProbeCatalog.Model.ps1` valide les identifiants, classes, champs et références ; `Domenia-Probes.Model.ps1` les joint au catalogue existant. L’atelier et le sélecteur de widgets consomment cette même définition. Les objets collectés suivent le circuit commun : lecture explicite, écriture SQLite confirmée, puis consultation des données enregistrées. Ajouter un widget ne lance pas automatiquement une collecte.

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
| Mémoire au relevé | `hw.memoryusage` | Mémoire visible et libre mesurées au même instant ; mesure datée, jamais confondue avec la capacité installée. [OperatingSystem](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem). |
| Système déclaré | `hw.computersystem` | Modèle, fabricant, famille et hyperviseur actif ; `HypervisorPresent` seul ne prouve pas une machine virtuelle. [ComputerSystem](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem). |
| Pilote de batterie | `hw.batterystatic`, `hw.batteryfullcharge`, `hw.batterycycles` | Capacité nominale, capacité à pleine charge et cycles par instance (root\wmi) ; zéro cycle = non renseigné. [BATTERY_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/power/battery-information-str). |
| Raccordement des écrans | `hw.monitorconnections` | Technologie de sortie (interne, HDMI, DisplayPort…) ; aucune station d’accueil revendiquée. [WmiMonitorConnectionParams](https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorconnectionparams). |
| Profils réseau | `net.connectionprofiles` | Catégorie de chaque connexion active, donc profil de pare-feu appliqué. [Get-NetConnectionProfile](https://learn.microsoft.com/en-us/powershell/module/netconnection/get-netconnectionprofile). |
| Antivirus déclarés | `sec.avproducts` | Produits du Centre de sécurité ; décodage de `productState` non documenté, donc estimé. [WSC_SECURITY_PRODUCT_STATE](https://learn.microsoft.com/en-us/windows/win32/api/iwscapi/ne-iwscapi-wsc_security_product_state). |

## Corrections sémantiques

- La fausse projection `sec.uac` (compte d’instances du système d’exploitation) est retirée. Elle ne mesurait pas `EnableLUA`. Le réglage documenté est distinct : [EnableLUA](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-lua-settings-enablelua).
- `sec.bitlocker` décrit la **protection** de C:, pas le simple chiffrement.
- `soft.hotfixcount` est intitulé « Correctifs CBS visibles », sans promesse d’exhaustivité des mises à jour.
- `sec.shares` est intitulé « Partages de fichiers déclarés » ; son filtre `Type=0` ne justifie pas à lui seul une affirmation d’exclusion des partages administratifs.

## Couverture réelle des points 81–110

Mise à jour du 15 octobre 2026 (lot W11-inventory). Les numéros restent non qualifiés tant que les fournisseurs n’ont pas été exécutés sous Windows.

- **Lectures interprétées** : `Domenia-Readings.Model.ps1` transforme les relevés enregistrés d’un poste en constats datés (constaté, estimé, inconnu, refusé, indisponible), avec source et limite. La fenêtre de détails d’une sonde lit uniquement les familles utiles du poste (`Families` de la lecture canonique, 16 au plus) et affiche cette lecture au-dessus des valeurs brutes.
- **Historique borné** : `disk.volumes` et `hw.monitors` conservent un historique dans la dernière charge réussie (`Add-DomeniaProbeHistory`, appliqué à l’écriture SQLite) : au plus 60 relevés espacés de 6 h pour les volumes, 20 ensembles d’écrans distincts. La prévision de saturation exige 4 relevés sur 14 jours, une taille constante et une tendance régulière ; sinon elle le dit.
- **Inventaire complet du poste** : emplacements et capacité maximale de la mémoire, état de santé inconnu distinct de « Sain », chiffrement et protection BitLocker séparés, Secure Boot lu comme DWORD, profils de pare-feu appliqués et réglage local masqué par la stratégie, stratégie WSUS appliquée, indices de redémarrage un par un (obligation confirmée ou indice partiel), dépendances des services automatiques arrêtés, charge processeur mesurée sur un intervalle borné (2 s), dernière exécution et résultat des tâches hors Microsoft (WinRM), certificats du magasin Personnel lus dans le registre sans clé privée.
- **Parc** : tableau croisé « Modèle × version du BIOS » dans l’analyse du parc ; références BIOS approuvées par modèle, enregistrées localement depuis la lecture BIOS d’un poste.
- **Diagnostic par couche** : nom, ICMP, transport TCP puis protocole ; un ping filtré sur un poste joignable n’est plus présenté comme un poste éteint.
- **Restent** : identification des stations d’accueil (aucune classe Windows normalisée), dernière exécution des tâches sans WinRM, qualification matérielle de tous les fournisseurs ajoutés.
- 101–109 : attributs et diagnostics AD, groupes/délégations/GPO/LAPS/réplication sont des sources AD distinctes. Ils ne sont pas maquillés en sondes CIM de poste.
- 110 : les nouvelles informations sont utilisables dans l’atelier ; les parcours guidés d’assistance et leur collecte minimale restent à raccorder explicitement.

## Validation préparée

`Test-DomeniaProbeCatalog.ps1` prépare huit cas sans accès réseau : identifiants, types/tableaux/unités, exclusions sensibles, absence de fausses conclusions de sécurité, limites batteries/QFE/processus/tâches, payload projeté, compatibilité des anciennes sondes, parsing des modules. **Suite non exécutée pendant ce lot**, conformément à la consigne de reporter les tests à la fin du développement. Les fournisseurs, performances à 20 000 postes et rendu Windows restent à qualifier.
