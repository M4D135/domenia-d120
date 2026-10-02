# Domenia 1.0 RC1.7

Emplacement fixe de la barre de chargement, du texte de tâche et d’Annuler dans le formulaire principal. Voir **CORRECTIF-ACTIVITE-FIXE-RC1.7.md**. Les diagnostics et moteurs métier restent identiques.

Aperçu local : `APERCU-ACTIVITE.cmd`. Tests Windows : `TESTER-ACTIVITE.cmd`. Le rendu WPF reste à valider sous Windows ; les rapports antérieurs ci-dessous sont historiques.

---

# Domenia 1.0 RC1.6

Correction de la fenêtre de connexion elle-même (pas de mini-journal pendant la validation) et du bandeau Opérations/Accès à dimensions fixes.

Voir `CORRECTIF-INTERFACE-STABLE-RC1.6.md`. Le mode aperçu de connexion peut simuler une attente sans authentification. Les tests Windows de présentation sont dans `TESTER-INTERFACE-STABLE.cmd`. Le correctif est une version de recette : aucune exécution WPF ou AD n’a été effectuée sur l’hôte de préparation.

Les chapitres ci-dessous décrivent aussi les versions précédentes et restent historiques.

---

# Domenia 1.0 RC1.5

Consulter **CORRECTIF-DEMARRAGE-LOGIN-RC1.5.md** en priorité. Cette révision corrige le compteur 55/54 et reprend le login FILPRO. Les documents suivants décrivent leurs versions historiques.

---

# Domenia 1.0 RC1.4

La recherche du bandeau est globale, la navigation OU est indépendante. Ping et utilisateur à la sélection uniquement.

Voir `wad/docs/CORRECTIF-RECHERCHE-PRESENCE-RC1.4.md`. Nouveau test Windows : `TESTER-RECHERCHE-PRESENCE.cmd`. Les instructions ci-dessous incluent l’historique de la version candidate.

# Domenia 1.0 RC1.3

Correctif sélection, restauration OU et en-têtes. Voir `wad/docs/CORRECTIF-SELECTION-RC1.3.md` pour le détail et la recette Windows.

PROD ne requiert aucun fichier de test ou de démonstration. Les rapports historiques ci-dessous se rapportent à leurs versions, pas à cette livraison.

---

# Domenia 1.0 RC1.2

Correctif des modules au démarrage. Lire `wad/docs/CORRECTIF-MODULES-RC1.2.md`.

Le nouveau test `TESTER-MODULES.cmd` utilise le même chargeur que le programme. Les rapports ci-dessous des versions RC1/RC1.1 restent historiques.

---

# Correctif de demarrage RC1.1

Cette distribution corrige les appels SDDL qui demandaient inutilement
`SeSecurityPrivilege` lors de la preparation des dossiers locaux et des recus.
Le meme correctif est applique au depot temporaire distant.

Lire **wad/docs/CORRECTIF-DEMARRAGE-RC1.1.md** pour la mise a jour,
les limites et la recette. **TESTER-ACL.cmd** est reserve a DEV.
Le moteur annonce `Domenia 1.0 RC1.1`. Le lanceur natif conserve ses octets RC1.
Les paragraphes ci-dessous decrivent le socle RC1, conserve hors de ce correctif.

---

# Domenia 1.0 RC1

Gestion du parc et de l’annuaire. Base : ADCC 1.0 R1.13.

**Candidat de recette, pas version certifiée sur un domaine réel.** Le code a été modifié et le lanceur compilé. Les contrôles portables, SQLite et intégrité réalisés sont fournis. Windows PowerShell, WPF et les opérations AD/CIM/WTS ne sont pas exécutés sur l’hôte de préparation. Voir `wad/docs/GUIDE-DOMENIA-RC1.md` et `wad/docs/M01-M42-COUVERTURE.md`.

## Démarrage

Conserver `Domenia.exe` et `wad` ensemble. Lancer `Domenia.exe` normalement. Windows PowerShell 5.1 x64 et WPF sont nécessaires. L’application n’est pas un EXE autonome. Elle ne télécharge pas de moteur, d’IA ou de composant au lancement.

Le déblocage se trouve dans **`wad/Support/DEBLOQUER_TOUT.cmd`**, dans les deux éditions. Ce script contrôle les fichiers runtime puis retire seulement la marque de téléchargement. Il ne change ni GPO, ni politique d’exécution persistante, ni antivirus. Un contrôle d’entreprise peut toujours refuser un binaire ou un script non signé.

## Mise à jour d’ADCC ou Domenia

Fermer toutes les instances après la fin des opérations et sauvegarder l’installation existante. Extraire DEV dans un dossier distinct et non imbriqué dans la destination. Depuis DEV :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Les données `wad/data` ne sont pas écrasées. Les configurations ADCC sont reprises lorsque celles de Domenia n’existent pas. Les sources anciennes ne sont pas supprimées. Après migration, utiliser **Domenia.exe**, plus l’ancien ADCC.exe. Pour conserver une racine propre destinée à diffusion, utiliser le ZIP PROD neuf : une mise à jour prudente d’un ancien dossier n’en supprime pas tous les vieux fichiers.

Ne pas remplacer seulement le cœur : les nouveaux modules et le manifeste sont nécessaires. Ne pas mélanger le runtime RC1 avec un ancien lanceur.

## Tests et aperçus DEV

- `VERIFIER-PACK.cmd` : fichiers, empreintes et syntaxe avec le vrai parseur Windows ; aucun accès AD.
- `TESTER-DOMENIA.cmd` : modèles, parsing des workers et du wrapper d’écriture, compilation des types C#, chargement WPF ; sans connexion au domaine.
- `APERCU-INTERFACE.cmd`, `APERCU-CONNEXION.cmd`, `APERCU-PROGRESSIF.cmd` : interfaces réelles avec données fictives. Aucun test réel de droits ni benchmark du parc.

Les anciens lanceurs de tests sont archivés sous `wad/docs/history/legacy-test-launchers`. Leurs anciens chemins et résultats ne constituent pas la recette actuelle.

## Construction facultative

```text
python tools/update_worker_contracts.py             # signale un corps d’opération modifié
python tools/update_worker_contracts.py --apply     # seulement après revue de la modification
python tools/launcher/build.py                     # clang + lld-link installés, sans téléchargement
python tools/audit_candidate.py --report wad/docs/AUDIT-DOMENIA-RC1.json
python tools/build_packages.py --output livraison
```

Une signature organisationnelle peut être appliquée avec `tools/Signer-Distribution.ps1`, puis les manifestes et archives doivent être reconstruits. Aucun certificat ni clé privée n’est fourni. Ne jamais régénérer les empreintes uniquement pour masquer un fichier corrompu ou non revu.
