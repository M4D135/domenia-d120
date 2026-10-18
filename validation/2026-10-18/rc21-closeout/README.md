# Clôture du labo Domenia — 18 octobre 2026

À la demande de David, le pack RC1.17.21 reste autonome pour son usage personnel : moteur M4D, DLL Active Directory/RSAT et PsExec embarqués. Choix consigné et poussé dans `a76ffc7` avant suppression de la VM cliente. Les droits de redistribution restent non établis ; aucune qualification générale supplémentaire n'est déclarée.

Avant nettoyage : 36 fichiers de preuve RC21 vérifiés par SHA-256 ; les ZIP PROD/DEV correspondent aux empreintes de `packs/manifest.json` et contiennent les quatre binaires des trois composants. L'inventaire des licences et `git diff --check` passent. Aucun nouveau test applicatif ni campagne VM.

`CNAMTS-W11-01` a été supprimée, avec ses trois disques, ses instantanés et ses deux dossiers dédiés. L'arrêt ACPI n'a pas abouti après 45 secondes : arrêt forcé de cette seule VM, déjà destinée à être supprimée. VirtualBox a d'abord désenregistré la VM et retiré le disque réinstallé ; un ancien disque différentiel inutilisé empêchait la suppression de sa base. Suppression terminée dans l'ordre enfant puis parent après vérification de l'absence de références par les autres VM.

Le reçu [lab-cleanup.json](lab-cleanup.json) confirme l'absence des dossiers/disques clients, le serveur `CNAMTS-DC01` toujours démarré, le même disque attaché et les quatre fichiers de sa chaîne de disques présents. Les six VM Pesto, FilPro et DEX sont conservées. Aucun nettoyage global de VirtualBox ni du serveur AD.

Les preuves de qualification et les packs restent dans le dépôt et sur le Mac. Pour toute qualification cliente Windows supplémentaire, il faudra disposer d'un autre poste ou recréer une VM cliente ; le serveur AD est conservé pour les autres projets. Les limites de qualification de RC1.17.21 restent celles de [rc21-remediation](../rc21-remediation/README.md).
