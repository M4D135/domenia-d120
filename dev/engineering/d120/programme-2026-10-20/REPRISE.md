# Reprise RC1.17.39 — programme des 60 points

## État au 20 octobre 2026, après checkpoint 92d2212

**Livraison non terminée.** Master et master distant restent `4987773325c0849129960c35b50790396ac1fc2b` (RC38). Dernier checkpoint poussé/vérifié : `92d2212f993686572c0bad38abef0aac0cf8cdd7`, branche `codex/rc39-60points-checkpoint`. Ce WIP contient code, suivi, guides et preuves, mais n'est pas un pack qualifié. Les changements de l'arbre postérieurs restent à sauvegarder au prochain jalon.

Instruction active : finir le code, contrôler indépendamment, puis **tests Windows critiques seulement**, corriger, régénérer DEV et PROD, commit/push master. Garder la VM et pousser le suivi aux jalons. Aucune écriture AD, aucun changement réseau/sécurité VM. Le point 59 (endurance étendue, DPI, accessibilité) reste hors de cette passe critique.

## Code et tâches encore actives

Les lots collectes 18–29, parcours/dashboard 30–48, stockage 49–54, aperçu mémoire/SQLite, découpage AssociationRows et documentation sont intégrés. Détail et limites dans `Suivi_60.json`, `Lot-*.md`, `Revue-Spark.md`.

- **6** : delta des champs simples et omission du remplissage identique prêts. Sécurité/identité/formes inconnues reprennent le chemin complet. Dernière revue corrigée : génération du panneau de connexions et invalidation des droits. LocalPreview comporte 21 cas ; les 2 nouveaux cas restent à exécuter.
- **38** : cache des plans avant résolution et réemploi réel des graphiques WPF. Dates, palette, largeur, contexte/snapshot et mutation en place invalident. Actions/DaysSince/données opaques restent hors cache. Parcours traite les dépendances Query Computer et les fournisseurs amont ; attendre son codegate.
- **8** : vrai modèle observable + conteneurs WPF recyclés en cours. Agent collectes possède Core arbre, Search/Continuity/Guard, Main.xaml, Modules, nouveaux DirectoryTree.Types.cs/UI.ps1 et tests arbre/navigation. Un seul OpenCode gratuit `glm-5.3-flash-free` low : tour `../stockage-20261020/turn-20261020T205828Z.jsonl`, prompt complet stdin `../tree-virtualization-20261020/prompt.txt`. Corrections supervisées préparées dans ce dernier dossier ; stockage relit sans nouveau LLM. Ne pas builder avant codegate. Préserver quota global/équité, groupes différés, annulation, identité/epoch et commit → SQLite → rendu.

Registres fermés, manifeste, contrats workers et preload doivent être rafraîchis **après** fin des écritures. L'audit précédent a passé sur 132 modules/3740 fonctions ; il ne couvre pas les nouveaux helpers/arbre. Ne pas relancer le runner 34 suites `Verify-60.ps1` abandonné.

## Preuves déjà conservées

Dossier `validation/2026-10-20/rc39-critical/`, candidat initial avant les derniers changements 6/8/38 :

- Démarrage/intégrité natifs, PS5.1 (342 fichiers sans erreur), StartupLogin 48/48.
- StoragePreferences 9/9, Maintenance 33/33, Faults 8/8 (SQLITE_FULL simulé par quota, pas disque physique rempli).
- RemoteStore 34/34, CollectCircuit 7/7 (AST), HealthRules 23/23.
- Après réparations des imports réels de fixtures : LocalPreview 19/19, LiveSearchView 16/16, WiringCache D024 1/1.
- AD/WMI/SQLite réels : cible expirée puis DC01 réussi, lot 2/2 dont 1 échec attendu, pas d'arrêt global. Premier délai réduit à 2 s pour le scénario.
- UIA : connexion, Premiers pas/OU sans collecte implicite, AD confirmé, dashboard, recherche, fiche, poste/santé, fermeture. Session verrouillée pendant cette passe : aucune preuve pixels. Session ensuite déverrouillée avec reçu LogonUI absent et capture bureau locale.

Guides sources RC39 et quatre DOCX/PDF régénérés, QA visuelle et synchronisation SHA réussies (`Guide-QA.json`, `DocSync.json`). Captures RC20 explicitement historiques. Pas de gain global de performance chiffré établi.

## Suite à exécuter

1. Recevoir les deux codegates, revue indépendante, régénérer registres/contrats et construire DEV+PROD.
2. Adapter `../../rc39-local-first/Verify-DeltaFinal.ps1` : nouveaux tests arbre/réalisation/navigation/favoris, LocalPreview21, Boards Programme38 et cas D024 ; nouveaux bancs AssociationRows/DiagnosticExport et règles modifiées ciblées. Ne pas répéter les suites inchangées.
3. Déployer dans de nouveaux dossiers, contrôle natif du pack final et réouverture/captures via `Visual-Final.ps1`. Vérifier réellement les pixels. Garder toutes les preuves d'échec puis les retests, liées aux SHA exacts.
4. Mettre Suivi/README/packs à jour ; reconstruire les archives si docs changent, vérifier parité applicative avec le candidat testé. Push master normal et vérifier SHA distant. Le garde formel Publishable=false n'est pas à contourner : recette labo critique ≠ qualification générale complète.

## Commandes et accès

Dépôt : `work/opencode-supervision-rc14/isolated-checkout`. Livraison : `https://github.com/M4D135/domenia-d120.git`. **Ne pas pousser origin**, qui est un ancien bundle local. Préserver les modifications concurrentes.

```sh
python3 dev/tools/integrate_lots.py --refresh-functions --apply
python3 dev/tools/update_migration_worker.py --apply
python3 dev/tools/update_worker_contracts.py --apply
python3 dev/tools/release_contract.py --stamp
python3 dev/tools/validate_powershell_static.py
python3 dev/tools/build_packages.py --output ../../rc39-local-first/packs
```

VM conservée `DOMENIA-FIRSTRUN-20261020`, UUID `bc2f1ac0-9545-49bd-a0f5-cb89d352cf61`, hôte `degun@192.168.1.173`, 1 vCPU/4 Go. Helper `../../rc38-final/lab.py`, guestcontrol par fichier opaque existant (ne pas lire son contenu). Récupération fraîche : `../../rc39-local-first/get.py`, ou depuis le workspace `work/rc35-qualification/pull.py`. Aucun secret dans scripts/journaux/Git. Keep-Console borné 45 min ; vérifier session avant le parcours final, sans changer de politique de verrouillage.

## Jalon suivant : code stabilisé et delta Windows lancé (21:19 UTC)

Codegates 6/8/38 reçus, revue indépendante sans défaut concret restant. Aucun OpenCode actif. Registre fermé, contrats97, release et contrôle lexical350 passent ; preload réépinglé avec décision de revue explicite. Packs candidats DEV `FCBB2FBC1FFEABA22482D26A0A7DD84F9F379DDC28260C8082795333DE574E4D`, PROD `9035B033D16C4E88DD545EA1741AC668BFB19EE858FA797F37508695FE233A8C`, 176 fichiers applicatifs identiques. Copies initiales conservées dans `../../rc39-local-first/packs-initial-critical`.

Déployés dans `RC39-final/dev` et `RC39-final-ui/prod`, empreintes contrôlées, profil isolé du candidat initial recopié application fermée. Session déverrouillée, LogonUI absent. `Verify-DeltaFinal.ps1` lancé ; sorties `rc39-final-delta`. Ne pas lancer de second runner. Chaque banc est borné à240s. Restent verdicts/corrections, pixels du pack PROD et publication master.
