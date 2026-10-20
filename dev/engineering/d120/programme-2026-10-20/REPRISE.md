# Reprise RC1.17.39 — programme des 60 points

## État au 20 octobre 2026, après checkpoint 8d031aa et retests R2/R4

**Livraison non terminée.** Master et master distant restent `4987773325c0849129960c35b50790396ac1fc2b` (RC38). Dernier checkpoint poussé/vérifié : `8d031aa65999a33c5c2aa42b8f89f9f5d81d914f`, branche `codex/rc39-60points-checkpoint`. Ce WIP contient code, suivi, guides et preuves, mais n'est pas un pack qualifié. Les correctifs et reçus R4 postérieurs restent à sauvegarder au prochain jalon.

Instruction active : finir le code, contrôler indépendamment, puis **tests Windows critiques seulement**, corriger, régénérer DEV et PROD, commit/push master. Garder la VM et pousser le suivi aux jalons. Aucune écriture AD, aucun changement réseau/sécurité VM. Le point 59 (endurance étendue, DPI, accessibilité) reste hors de cette passe critique.

## Code et tâches encore actives

Les lots collectes 18–29, parcours/dashboard 30–48, stockage 49–54, aperçu mémoire/SQLite, découpage AssociationRows et documentation sont intégrés. Détail et limites dans `Suivi_60.json`, `Lot-*.md`, `Revue-Spark.md`.

- **6** : delta des champs simples et protections intégrés ; R2 LocalPreview **21/21**, y compris génération du panneau de connexions, invalidation des droits, fraîcheur/secrets. Les formes sensibles/inconnues gardent le remplissage complet.
- **38** : caches de plans/cartes, record Query Computer exact et fournisseur logiciel intégrés. R2 QueryTargets **39/39**, Boards Programme 38 **4/4** ; `SelectionComplete=true`, `Complete=false` (pas les 73 cas). Aucun gain global chiffré.
- **8** : modèle observable et virtualisation des conteneurs intégrés. R2 compilation, TreeRendering **4/4**, Navigation Programme 8 **5/5** (sous-ensemble). Après les trois échecs R2/R3 et correction du trigger de thème imposant un panneau standard, R4 TreeVirtualization **8/8** : WPF réel, 10 000 DTO synthétiques, 40 conteneurs au premier relevé, maximum 61 sur neuf cibles. Aucun AD/réseau réel ni benchmark mémoire du processus. Aucun OpenCode actif.
- **WiringRecherche** : R4 lancé sans filtre, **47/53** ; les dix cas visés en R2 passent. Six autres échecs restent confiés à parcours pour correction/retest. Le résultat de l’arbre ne clôture pas ce banc séparé.

Registres fermés, manifeste, contrats workers et preload doivent être rafraîchis **après** fin des écritures. Le candidat R1 a passé le contrôle de 176 fichiers/133 modules ; les hashes doivent être renouvelés après les corrections finales. Ne pas relancer le runner 34 suites `Verify-60.ps1` abandonné.

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

1. Corriger/rejouer les six échecs WiringRecherche R4 ; conserver les échecs initiaux et leurs retests. Runtime gelé après le dernier correctif confirmé, sans nouvelle génération.
2. Rapprocher les hashes des preuves R1/R2/R3/R4, régénérer registres/manifestes si nécessaire et construire les archives DEV/PROD finales. Ne pas répéter les suites inchangées.
3. Contrôler le démarrage natif du pack final et réouvrir/capturer avec `Visual-Final.ps1` ; vérifier réellement les pixels.
4. Finaliser Suivi/README/packs, vérifier la parité applicative avec le candidat testé, puis push master normal et SHA distant. Le garde formel Publishable=false n'est pas à contourner : recette critique ciblée ≠ qualification générale complète.

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

## Delta1 terminé ; corrections et relance ciblée

Checkpoint code stable vérifié `81ac0cb66a246bce9061d5fa9ffd030f7fd0017a`. Résultats delta1 dans `validation/2026-10-20/rc39-critical/rc39-final-delta` : modules 185/185, QueryTargets 39/39, favoris 20/20, associations 5/5, diagnostic 4/4, D024 1/1 et quatre fichiers de règles passent. Échecs corrigés : référence System.Xaml/System.Core (runtime arbre), vraie vérification de type PSCustomObject (runtime cache), fixtures UTC/Filter dupliqué/import réel Park. Aucun OpenCode actif. Relance `Verify-DeltaRetest.ps1`, sorties `rc39-final-retest`, à lancer après patch des candidats. Ancien harnais ExitCode=null ; nouveau harnais Process .NET conserve les vrais codes. Archives delta1 conservées dans `packs-final-r1`, originales critiques dans `packs-initial-critical`.

## Retests R2/R4 confirmés ; six cas WiringRecherche encore en correction

R2 dans `validation/2026-10-20/rc39-critical/rc39-final-retest` : LocalPreview 21/21, QueryTargets 39/39, Boards Programme 38 4/4 (`SelectionComplete=true`, `Complete=false`), TreeRendering 4/4, Navigation Programme 8 5/5 (`Complete=false`), règles pures Park 14/14. Les autres succès R1 restent inchangés : modules 185, favoris 20, associations 5, diagnostic 4, D024 1 et règles BoardFleet 26/Collection 49/DirectorySync 11/Observability 17.

R4 `rc39-tree-r4/TreeVirtualization.json` : 8/8 sous WPF réel, 10 000 données synthétiques, maximum 61 conteneurs sur neuf cibles (premier relevé 40). Les échecs R2/R3 restent conservés ; le panneau standard imposé par le trigger hérité a été corrigé. Ce résultat ne mesure pas la mémoire du processus et ne qualifie pas un parc AD réel. WiringRecherche R4 a été lancé sans filtre : 47/53 ; les dix cas visés en R2 passent, six autres échecs sont en correction/retest chez parcours. Voir le README des preuves pour les liens et limites exactes. Point 59 hors passe ; `acceptance_passed=false` et qualification générale ouverte.
