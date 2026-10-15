# Relais Codex — Domenia, 16 octobre 2026

Tu reprends le chantier Domenia après une session Claude Code. Lis ce document en entier avant d'agir, puis `CLAUDE.md` à la racine du dépôt (règles non négociables : Windows PowerShell 5.1 + WPF uniquement, C# 5, `.ps1` en UTF-8 avec BOM et fins de ligne LF, aucun guillemet typographique dans le code, `ʼ` U+02BC pour l'apostrophe d'interface, `-and`/`-or` parenthésés, lecture seule par défaut, aucune écriture AD rejouée, aucun parcours de tout le domaine, aucun secret dans le dépôt ou une ligne de commande, ne pas recompiler `Domenia.exe`).

## Où tout se trouve

- Dépôt : `/Users/david/Documents/Projets/Domenia-D120`, branche `master`, poussée sur `https://github.com/M4D135/domenia-d120` (privé). État de référence : `d32432d` (« merge(Z09-sqlite-ops) »). Le dépôt est propre.
- Worktrees de l'équipe : `/Users/david/Documents/Projets/Domenia-D120-team/<lot>`, branches `team/<lot>`. Presque tous sont déjà fusionnés dans master ; seuls `team/Z06-dead-code` et `team/F01-localstore-mirror` portent du travail non fusionné (voir plus bas).
- Pilotage : `/Users/david/Documents/Projets/Domenia-D120-team/_pilotage/` (hors dépôt) :
  - `RULES.md` : règles de l'équipe (référence pour tout lot) ;
  - `points-final.json` : statut final de chaque point des 160, avec le lot, le résumé et les preuves ;
  - `triage-items.json` : tri vérifié des 154 points et des 87 pistes du 8 octobre, au 14 octobre ;
  - `A-REVOIR.md` : points notés pendant les fusions ;
  - `catch-flags-spark.json` : 72 blocs `catch` signalés par le Spark (déjà traités par le lot Z07) ;
  - scripts d'intégration : `merge_lot.sh`, `finish_merge.sh`, `integrate.sh`, `help_merge.py`, `lot_report.py`, `ledger.py` (chemins déjà réglés sur ce dossier ; `integrate.sh` lit les rapports des agents Claude, ignore cette partie).

## Ce qui est fait (sur master)

Sauf indication contraire, tout est codé et vérifié hors Windows : contrôle statique, audits Python et build des paquets. Rien n'a été exécuté sous Windows PowerShell 5.1. Décision de David : il fait lui-même les tests en VM, à la main. N'en lance aucun, ni campagne ni simulation.

- **160 points de la feuille de route** (`programme-2026-10-13/FEUILLE-DE-ROUTE.md`) : 159 codés.
  - 9 sont des points de pure qualification Windows : 41, 43, 106, 114, 116, 125, 126, 129, 130. Leurs suites de test sont écrites ; David les exécutera.
  - Reste le point **131** (« Extraire progressivement le cœur monolithique »), plus bas.
- **Pistes du 8 octobre** : lots X01 à X07 et Z01 à Z04, Z07, Z08 et Z09 fusionnés :
  - Z07 : balayage des `catch` muets, seuil de l'audit 1 321 → 274 ;
  - Z08 : passe de langue, fautes de l'audit 341 → 27 ;
  - Z09 : une seule couche SQLite des workers et une table déclarative des opérations.
- **Demandes explicites de David sur les widgets** (lot W01, fusionné) :
  - chaque widget s'actualise seul ;
  - un widget ajouté collecte aussitôt ce qui lui manque ;
  - « Suspendre la mesure » garde le widget au tableau sans charge réseau.
- Registre des opérations épinglées : 94 opérations dans `dev/tools/operation-contracts.json`.

## Ce qu'il reste à faire, par priorité

1. **F01 — vérifier les corps composés épinglés (critique).** Le lot Z09 a signalé que `composed_body()` de `dev/tools/update_worker_contracts.py` pourrait ne pas reproduire exactement le corps que l'application compose et hache au démarrage pour LocalStore. L'application compose 9 modules, dont ProbeCatalog, QuerySchema et Workstation, ne garde que les fonctions de premier niveau et ajoute une ligne de catalogue JSON. Si c'est vrai, LocalStore serait refusée à l'exécution, et la base locale avec.
   - Reconstitue octet par octet ce que le cœur hache pour chaque opération composée : `Get-DomeniaWorkerOperationHashes`, `Assert-DomeniaWorkerRegistry`, `New-DomeniaWorkerRunspace` et les générateurs de corps.
   - Compare avec `composed_body()` et avec le constructeur PROD (`dev/tools/Production.Source.ps1`, `Get-DomeniaBuildWorkerBody`).
   - Écris un contrôle permanent `dev/tools/check_worker_composition.py` avec ses tests unitaires, et corrige le miroir si besoin. N'affaiblis jamais la vérification d'exécution.
   - Corrige aussi les deux tests qui ne hachent que le littéral : `Test-Domenia.ps1` (« Corps introuvable ») et `Test-DomeniaStartupLogin`.
   - Le worktree `F01-localstore-mirror` existe, sans modification.
2. **Z06 — code mort (pistes CD-02, CD-03, CD-04, SE-14, SP-11).**
   - La branche `team/Z06-dead-code` contient un commit `wip` non relu : 11 fichiers, 983 lignes supprimées.
   - Relis chaque suppression en prouvant par grep qu'aucun appel n'existe, y compris dynamique : noms de handlers en chaîne, `Get-Command`, `Add_Click`, here-strings des workers.
   - Termine, fais tomber le cliquet avec `python3 tools/audit_dead_functions.py --update`, puis fusionne. La consigne complète est dans `Domenia-D120-team/Z06-dead-code/TACHE-Z06.md`.
   - À trancher au passage, selon `A-REVOIR.md` : `Get-DomeniaSelectedMachineRows`, désormais mort, et les 8 fonctions de l'atelier support devenues inaccessibles.
3. **Point 131 / lot L24 — extraction du cœur.**
   - Sors le XAML principal (`Get-MainXaml` dans `dev/wad/Domenia-Core.ps1`) vers `dev/wad/Domenia-Main.xaml`, chargé et validé au démarrage comme les vues `.xaml` existantes (modèle : `Initialize-DomeniaSupportUi`). Il doit être intégré aux manifestes, au paquet et aux contrôles, et `strip_xaml_help.py`, `audit_typography.py` et `audit_theme.py` doivent lire le nouveau fichier.
   - Ensuite, extrais progressivement des familles de fonctions du cœur vers des modules déclarés dans `Domenia-Modules.ps1`.
   - Respecte `audit_preload.py`, dont les fonctions critiques et la baseline se rebaselinent seulement avec `--decision` après relecture.
4. **Registre.** Mets à jour `programme-2026-10-13/EXECUTION.json` et écris `SUIVI-2026-10-16.md` à partir de `_pilotage/points-final.json` (script `_pilotage/ledger.py`). Ajoute les points faits avant l'équipe :
   - 8 et 51 : validés hors Windows ;
   - 25 et 26 : commit `ff4d18a` ;
   - 38 : `4943481` ;
   - 47 : `56cfb7f`.

   Statuts : « codé, qualification Windows à faire », ou « qualification Windows seule » pour les 9 points ci-dessus. Aucun point n'est « clos » sans rapport Windows PowerShell 5.1 lié au ZIP.
5. **Petits restes connus.**
   - `test_lang_pass` échoue sur des entrées « UnusedCleared » (32) de `langue-dependances-ecartees.json`, devenues inutiles après la passe de langue : nettoie la liste.
   - 7 marges littérales ajoutées par Z04 dans `Get-MainXaml` : la référence d'`audit_typography` a été relevée de 1 110 à 1 117 ; convertis-les en ressources d'espacement.
   - 11 opérations épinglées ont un effet « Unknown » dans la table de Z09 : classe-les.
   - 274 `catch` muets restent dans le code des workers (here-strings) et dans `Invoke-DomeniaInProcessAuthProbe` : ne les trace que si une fonction de trace est disponible dans leur runspace.
   - Docs : 56 figures et la régénération DOCX/PDF sont à faire sous Windows par David.

## Procédure d'intégration (une branche de lot vers master)

Depuis `dev/`, après la fusion (`git merge --no-ff team/<lot>`) :

1. `python3 tools/integrate_lots.py --refresh-functions`
2. Pour une nouvelle opération : `python3 tools/update_worker_contracts.py --add <Operation> <Fonction> --file <fichier> --apply`
3. `python3 tools/update_worker_contracts.py --apply` : ré-épingle les corps modifiés, après relecture.
4. `python3 tools/validate_powershell_static.py` : doit afficher PASS.
5. `python3 tools/audit_wording.py --update`, puis `python3 tools/audit_wording.py` : aucune nouvelle entrée.
6. `python3 tools/audit_swallowed.py --update`, puis `python3 tools/audit_swallowed.py` : le cliquet ne doit plus monter.
7. `python3 tools/audit_preload.py --rebaseline --source . --decision "<décision relue>"`, puis `python3 tools/audit_preload.py` : 0 FAILED.
8. `python3 tools/build_packages.py --output <dossier hors arbre>` : régénère les manifestes. Il appelle aussi `doc_sync`, `audit_typography`, `licence_inventory`, `compiled_code` et `update_migration_worker`.
9. Commit, puis push sur `origin master`.

Conflits fréquents :
- fichiers générés : prends la version de master puis régénère ;
- `Domenia-UX.help.json` : fusion à trois voies par `Name` (`_pilotage/help_merge.py`) ;
- listes d'opérations : union ;
- ajouts de fonctions au même endroit : vérifie que chacune garde son accolade fermante.

## Outils à ta disposition

- **Spark** (LLM local) : `~/bin/kbza ask --prompt-file FICHIER --no-memory --max-tokens 0`. Petites requêtes, 3 en parallèle au plus, ressource partagée avec d'autres sessions. Ses réponses sont des brouillons : vérifie toujours. Exemple : sa relecture de langue avait voulu mettre à l'infinitif des consignes au vouvoiement ; elle a été rejetée.
- **OpenCode CLI** (`opencode run -m opencode/deepseek-v4.1-flash-free --auto ...`) : installé, mais le modèle gratuit était en « rate limit » le 15 au soir, car il est partagé avec la session FILPRO. N'utilise pas les modèles OpenCode Go qui entraînent sur les requêtes : David ne l'a pas autorisé.
- Pas de PowerShell sur ce Mac : tous les tests `.ps1` restent à exécuter par David sous Windows.

## Ce que David attend

- Le meilleur code possible.
- Le code d'abord ; les tests VM, c'est lui, à la main.
- Pousser au fil de l'eau.
- Un résumé final honnête : ce qui est fait, vérifié, poussé, et ce qui reste à qualifier sous Windows.
