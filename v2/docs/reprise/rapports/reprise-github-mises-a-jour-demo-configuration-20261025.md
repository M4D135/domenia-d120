# Revue des mises à jour, de la démonstration et de la configuration diffusée

Relecture ciblée du 25 octobre 2026 sur la branche `codex/v2-finalisation-20261025`, jusqu'au lot Atelier `c84b633c`.
Les exigences de `DEMANDE-MISES-A-JOUR-DEMO-20261025.md` sont confrontées aux consommateurs du dépôt.
Cette revue est statique : **aucun test exécuté ni recette native effectuée**. Aucun nouveau défaut bloquant
n'a été prouvé dans les parcours ci-dessous ; cela ne constitue pas une certification du catalogue entier.

## Raccordements trouvés

| Parcours | Consommateurs et limites observées |
| --- | --- |
| Mise à jour GitHub, dossier/partage ou ZIP | `web/js/pages/parametres/mises-a-jour.js` appelle `settings.update.check/prepare/install`, déclarées dans `App/Settings/PackageUpdateHostOperations.cs`. `PackageUpdateSources` et `PackageUpdateArchive` qualifient la source, les redirections, tailles, SHA et composants. `MainForm.PackageUpdateHost.cs` raccorde les sélecteurs natifs ; `MainForm.Transitions.cs` draine les travaux avant `PackageUpdateAssistant`. Aucun repli implicite vers une autre source trouvé. |
| Récupération réelle | `PackageLifecycleCommand.cs` fournit `livraison apercu-reprise/reprendre` et `apercu-restauration/restaurer`, depuis un paquet distinct ; `docs/MISES-A-JOUR.md` explique ce parcours. La page Paramètres propose seulement une restauration fictive en démonstration. Le contrôle de santé atteste l'intégrité, le runtime et l'affichage local, sans attester la connexion AD ou les données métier. |
| Démonstration isolée | `settings.demo.open` rejoint `MainForm.Demonstration.cs`, qui lance le même EXE avec `--demo-session` seul. `Program` et `Composition` imposent la source simulée ; `AppPaths` sépare profil, journaux et exports. Parent suspendu, réinitialisation, sortie, bandeau permanent et exports marqués sont raccordés. Les mises à jour réelles et partages sont refusés avant acquisition ; le sélecteur de démonstration reste borné aux exports fictifs. |
| Configuration distribuable | `configuration-distribuable.js` raccorde sélection, aperçu, export/import et préparation d'une nouvelle copie par `PackageDefaults.Create`. `ConfigurationSeedHost.InitializeAsync` précède les modules et initialise le profil vierge. `startConfigurationDefaults` propose le changement aux profils existants ; le commit requalifie l'empreinte, sauvegarde les octets existants puis remplace atomiquement. Les réglages métier importés pendant une session s'appliquent au prochain démarrage, annoncé à l'utilisateur. |

## Preuves encore absentes

Les transitions entre processus Windows, SMB réel, acquisition depuis une Release réelle, restauration après incident,
premier lancement sur les deux profils, archives finales et captures UI/native restent **NON VÉRIFIÉS**. Les tests
critiques locaux sur GitHub pourront contrôler leurs fixtures ; ils ne remplaceront pas la recette dans
`CNAMTS-DC01` et `DOMENIA-FIRSTRUN-20261020`.

Aucune dépendance téléchargée, aucun service/runtime/réseau modifié et aucune écriture AD, publication, fermeture de
session ou redémarrage effectué pour cette revue. `dev/` demeure en lecture seule. Les paquets PROD/DEV v2.0.0 et leur
publication SHA256 restent conditionnés aux preuves critiques réelles des deux VM.
