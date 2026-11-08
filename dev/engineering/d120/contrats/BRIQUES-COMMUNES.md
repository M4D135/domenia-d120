# Briques communes avec Pesto et FILPRO (point 134)

État au 15 octobre 2026. Contrat tenu **dans ce dépôt seulement** : les dépôts Pesto, FILPRO et `m4d-admin-common` n’ont
été ni modifiés ni consultés. La revue des besoins réels s’appuie uniquement sur les preuves présentes ici ; un besoin
non prouvé est écrit « non vérifié », jamais supposé.

Source de vérité lisible par machine : [`briques-communes.json`](briques-communes.json) (`Domenia.SharedBricks/1`).
Contrôle automatique : `python -m unittest discover -s tools/tests` (`tools/tests/test_shared_bricks.py`) vérifie que
chaque fichier et chaque fonction déclarés existent une seule fois, que chaque preuve citée est présente, qu’une brique
pure ne fait ni WPF, ni réseau, ni disque, et que la bibliothèque de requêtes a l’empreinte déclarée.

## Inventaire

| Brique | Statut | Nature | Sources dans Domenia | Besoin Pesto | Besoin FILPRO | Reste à faire |
|---|---|---|---|---|---|---|
| Requêtes | Partagée | Natif | `M4D.Admin.Common.Query.dll` (amont `m4d-admin-common`, empreinte dans `Domenia-CommonLibrary.json`), `ConvertTo-DomeniaCompiledQuery`, schéma de la bibliothèque | non vérifié | non vérifié | reverser la modification locale de `QueryEngine.cs` avant d’étendre la bibliothèque |
| Identité | Candidate | Pur | GUID/SID canoniques, clés de compte et de poste, refus d’un autre domaine (`Test-DomeniaInventoryIdentity`) | même forme attendue par `DomeniaSuiteContract/1` (à confirmer) | idem | regrouper dans un module d’identité sans dépendre de Relations |
| Coffre | Candidate | Natif | `Domenia-CredentialVault.Model.ps1` + `.Native.cs` (gestionnaire d’identification Windows) | non vérifié | non vérifié | préfixe de cible par produit ; qualification Windows (point 43) |
| Journal | Extraction requise | Mixte | `Protect-DomeniaSecretText` (pur), `Protect-DomeniaLogText` et `Write-AppLog` (cœur) | non vérifié | non vérifié | séparer la règle de masquage de l’écriture du cœur (point 131) |
| Composants GUI | Partagée | Données | `SupportSuite.UI.json` versionné par empreinte, `Get-DomeniaSuiteKitManifest`, styles de connexion repris de FILPRO 2.5.0 | non confirmé : le kit nomme DOMENIA, GP et RBP | établi : `RC1.5-FILPRO-reference.json` | établir GP/RBP ↔ Pesto/FILPRO ; valider la même version dans chaque produit |
| Passage de contexte | Propre à Domenia | Contrat | `DomeniaSuiteContract/1`, `Open-DomeniaSuiteTool` (exécutable contrôlé par empreinte) | établi : bouton « Ouvrir Pesto » | établi : bouton « Ouvrir FILPRO » | chaque outil publie son `suite-contract.json` |
| Automatisation et sondes | Propre à Domenia | Contrat | `Domenia.Automation/1` (`wad\Domenia-Automate.ps1`), `Domenia.ProbeContract/1` | non vérifié | non vérifié | aucun pour Domenia : un consommateur lit le JSON versionné |

## Règles d’extraction vers la bibliothèque commune

1. Windows PowerShell 5.1 et C# 5 seulement ; une règle n’utilise ni WPF ni l’état `$script:` du cœur.
2. Aucun accès réseau, annuaire ou disque au chargement ; aucun secret dans le code, un journal ou un argument de processus.
3. Version sémantique et empreinte SHA-256 du contenu ; le consommateur vérifie l’empreinte avant chargement, sans
   téléchargement à l’exécution (`RuntimeDownload: false`).
4. Les tests de règles portables accompagnent la brique ; une diffusion n’est autorisée qu’après validation de la même
   version dans chaque produit consommateur (`Test-DomeniaSuiteKitDiffusion`).
5. Une modification locale d’une brique amont est déclarée (`LocalModification`) et reversée avant la version suivante.

## Ce qui reste hors de ce dépôt

- Confirmer avec les mainteneurs de Pesto et de FILPRO les besoins notés « non vérifié » et la correspondance GP/RBP.
- Reverser `QueryEngine.cs` dans `m4d-admin-common`, puis y publier les briques « Candidate » validées.


## Relais prêt au 18 octobre 2026 (RC1.17.16)

Source à intégrer par l’amont : `dev/vendor/m4d-admin-common/src/Query/QueryEngine.cs`, SHA-256 `4ee562b205eb761e0c7f1fe1c1e4e45b7a2d0751b45c8b6f59ccde28338f474e`. API et règles de valeurs inconnues : README voisin. Tests portables : `dev/vendor/m4d-admin-common/tests/Query/Test-Query.ps1`. DLL livrée : empreinte dans release-contract.json, compilation Windows déterministe déjà attestée en RC13.

Domenia emploie désormais le même compilateur pour les alertes de santé à définition figée, en plus des widgets, listes et rapports. Les données absentes restent inconnues et aucune collecte ne fait partie du moteur commun. Le dossier est prêt pour revue ; il ne prouve ni l’acceptation par les mainteneurs ni une mise à jour de leurs dépôts. Décisions attendues : version/API commune, besoins Pesto/FilPro et autorisation de redistribution M4D. Aucun transfert externe n’a été envoyé.
