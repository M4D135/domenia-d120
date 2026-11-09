# Relais vers Codex — Domenia 2, 9 novembre 2026

Ce fichier est le prompt maître de la relève. Claude Code passe la main à Codex après la publication de Domenia 2.1.1.
Le but de David est de **boucler Domenia 2** : stabiliser la version publiée à partir des retours de production, puis
fermer les dernières fonctions de parité.

## 1. Où travailler

- Clone de travail, **le seul autorisé à pousser** :
  `/Users/david/Documents/Codex/2026-10-26/go/work/domenia-d120-recree` (GitHub `M4D135/domenia-d120`, public).
- Le dépôt a été recréé le 9 novembre. Il ne contient que `master` et les tags `v2.0.8`, `v2.1.0` et `v2.1.1`.
- Les anciens clones (`domenia-d120`, `domenia-fix-gate-20261108`, `domenia-integration-22-lots`,
  `domenia-l*-claude`, `~/Documents/Projets/Domenia-D120`…) ont une URL de push neutralisée. Ne jamais y travailler, et
  ne jamais repousser une de leurs branches ou un de leurs tags. Les SHA d'avant la recréation n'existent plus sur GitHub.
- Git :
  - jamais de push forcé ni de réécriture d'historique ;
  - un sujet = une branche `codex/<sujet>-AAAAMMJJ` ;
  - intégration à `master` seulement après CI verte et relecture ;
  - commits limités aux fichiers de la tâche.
- Utiliser des chemins absolus et `git -C <clone>`, sans `cd` dans d'autres clones.

## 2. Lire d'abord

1. `CLAUDE.md` à la racine. Pour la v2, seules les « Règles non négociables » 2 à 5 s'appliquent ; le reste concerne
   la v1 PowerShell.
2. `v2/CLAUDE.md`. Attention, la section « Développement » date d'avant la CI hébergée : on compile et on teste
   maintenant par GitHub Actions (§ 6).
3. `v2/REPRISE.md`, sections du 9 novembre en haut du fichier.
4. `v2/docs/DECISIONS.md`, en particulier « 9 novembre 2026 — le poste décide, pas le groupe Domain Admins ».
5. `v2/ARCHITECTURE.md` avant de toucher au code.

## 3. État au 9 novembre 2026, 17 h

- **Production : Domenia 2.1.1 PROD-LIGHT**, release
  [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1), Latest, publiée le 09/11 à 15:44 UTC.
  - Tag sur `7627bd1e50d9b72a255f98b8d980f4496cb59397`.
  - ZIP `Domenia_2.1.1_PROD-LIGHT_Windows-x64.zip`, SHA-256
    `85d795d75b332a9008de14c235ca81b788d44a4006e510e86c7f6c568689f8b2`, avec `SHA256SUMS.txt`.
  - README, `packs/` (README, `manifest.json`, `SHA256SUMS`) et description du dépôt sont à 2.1.1.
- **Qualification 2.1.1** : run de livraison
  [42641992867](https://github.com/M4D135/domenia-d120/actions/runs/42641992867), tout vert :
  - C# : 3 028 tests (suite complète) et 1 586 critiques ;
  - 218 contrôles navigateur et 7 scénarios de simulation ;
  - login natif hors connexion réussi, fermeture avec le code 0 ;
  - le nom du domaine de labo est absent des 788 fichiers du ZIP.
- **Ce que change 2.1.1** :
  - le ping et le DNS de la présence ne demandent plus aucune administration ;
  - une lecture distante faite avec la **session Windows** est tentée, et le poste accepte ou refuse ;
  - les comptes saisis (connexion explicite, temporaires, locaux) et toutes les écritures distantes gardent
    `RequireAdministration`. Code : `WorkstationDecides(readOnly, origin)` dans `v2/src/Domenia.Ad/AdWorkstationAccess.cs` ;
  - le login NetBIOS `DOMAINE\compte` est accepté partout.
- **2.1.0** : la connexion AD a réussi sur le banc le 09/11 (kit `94851344`, rapport hors dépôt SHA-256 `f771d12d…`).
  La 2.1.1 n'est pas passée au banc : elle ne touche ni le démarrage ni la connexion.
- **Non vérifié** :
  - 2.1.1 avec un compte hors Domain Admins sur un vrai domaine. David l'essaie en production ;
  - la recette manuelle (`v2/docs/RECETTE-MANUELLE-V2.1.1.md`) ;
  - les performances sur un domaine réel. Les tests de 3 500 et 100 000 postes sont simulés.
- **Parité** (`v2/docs/features.json`) : 619 fonctions faites, 370 améliorées, 1 partielle, 2 à faire, 1 abandonnée
  (PST-001, sur décision de David).

## 4. Reste à faire, dans l'ordre

1. **Retour de production sur 2.1.1.** David mesure la présence et lance l'inventaire avec un compte hors
   Domain Admins.
   - Tout refus ou défaut remonté : le reproduire par un test C#, corriger, puis livrer 2.1.2 selon le cycle du § 6.
   - Ne pas rouvrir le contrôle d'administration sur le ping ni sur les lectures avec la session Windows : c'est
     une décision datée de David.
   - Pour les refus par poste : ils s'empilent comme demandes d'accès en attente (16 au plus), via
     `AccountAccess.RegisterRefusal`. Le dialogue ne s'ouvre que sur clic du badge `.sh-access`.
2. **TRV-111 « Populations comparables »** et **TRV-190 « Contrat de sonde Domenia.ProbeContract/1 »** sont `a-faire`,
   parce que l'audit du 31/10 n'a pas retrouvé la preuve dans le code.
   - Chercher d'abord si elle existe. Si oui, la citer (`fichier:ligne`), ajouter un test dédié s'il manque, puis passer
     la fonction à `fait`. Sinon, l'implémenter avec ses tests.
   - Garde-fous à respecter, tels qu'écrits dans `features.json` :
     - TRV-111 : une description absente n'est jamais présumée identique ;
     - TRV-190 : lecture CIM seulement, aucune méthode WMI ni écriture, et un coût lourd exige une collecte explicite.
3. **PAR-046 « Réglages réseau, accès distant et budgets »** est `partiel`.
   - `Remote.CommandTimeoutSeconds` reste réservé au lot L02.
   - Portée et limites : `v2/docs/reprise/LOTS-CODEX-20261101/L16.md`.
4. **Statuts de parité.** Ne pas éditer `features.json` et `FEATURES.md` à la main l'un sans l'autre : passer par
   `v2/docs/status/*.json` et `python3 -I v2/docs/reprise/apply_status.py`.
5. **Dette mineure** : `v2/tools/capture-release-evidence-vm.ps1` suit encore l'ancienne disposition à plat des
   packs. À aligner ou à déclarer hors usage.
6. **Recette manuelle 2.1.1.** C'est un geste de David. Codex peut préparer, mais ne déclare jamais une étape réussie
   sans preuve.

Chaque version publiée garde le même format de données : une base de 2.0.5 à 2.1.x s'ouvre telle quelle. Toute
évolution de schéma est une décision de David.

## 5. Règles non négociables

- **Secrets** :
  - aucun mot de passe, jeton ou clé dans le dépôt, un script, un rapport, une note, un commit, un message ou un
    argument de processus ;
  - ne jamais ouvrir, afficher ni recopier les fichiers de mot de passe du labo, même si leur chemin apparaît
    quelque part ;
  - si David écrit un mot de passe dans le chat, ne jamais le répéter.
- **Lecture par défaut** : aucune sonde réseau, aucun scan et aucune écriture AD sans geste explicite de l'opérateur.
  Aucune écriture n'est rejouée automatiquement. Ne pas affaiblir Windows (pare-feu, WinRM, Defender, certificats,
  stratégies).
- **Banc AD et VM du labo** :
  - pas d'accès direct, et ne jamais toucher à Defender ni supprimer d'artefact ;
  - les créneaux passent par la session Claude de coordination du banc. Codex ne peut pas la joindre : il prépare le
    kit et le donne à David, qui le transmet ;
  - **seul David ouvre la session Windows de la VM**. Ne jamais demander à un autre agent de le faire à sa place.
- **Tests** : jamais sur l'hôte Windows. La compilation et les tests C# passent par la CI hébergée `windows-2025`.
  GitHub reste gratuit : dépôt public, aucune facturation, aucun runner auto-hébergé.
- **Dépendances** : aucune dépendance téléchargée sans accord explicite de David. Les paquets NuGet viennent de
  `v2/vendor/nuget/`.
- **README et `packs/`** : rien sur le domaine (nom, OU, comptes, adresses). Les docs internes, tests, `validation/` et
  `dev/` gardent le nom du domaine de labo. Le produit (ZIP) ne doit jamais le contenir.
- **Publication** : une release, une modification de release ou une suppression d'asset demande la **confirmation
  explicite de David dans le chat**. Après chaque publication, mettre à jour README, `packs/` et la description du
  dépôt ; David l'a exigé (« y'a pas de 2.1 !! »).
- **Preuves** : aucune preuve inventée. Un test non exécuté est déclaré non exécuté. Annoncer exactement ce qui est
  appliqué, validé, poussé ou bloqué.
- **Économie** :
  - le Spark fait le gros des relectures et des brouillons ; Codex cadre, décide et vérifie ce qu'il rend ;
  - pas de workflow multi-agents ni de rafale de sous-agents sans demande explicite de David ;
  - commande : `~/bin/kbza ask --prompt-file F --no-memory --reasoning-effort low --max-tokens 0 --timeout-seconds 900`.
    Prompts de 35 000 caractères au plus : au-delà, les relectures bouclent.

## 6. Cycle de livraison d'une version 2.1.x

1. **Code et tests** sur `codex/<sujet>-AAAAMMJJ`. Le push déclenche `domenia-v2-windows.yml` (compilation Windows
   hors ligne) pour tout changement sous `v2/**`.
2. **Changement de version** : chercher l'ancienne version avec `git grep -F "2.1.1" -- v2`. Fichiers concernés :
   - `v2/Directory.Build.props`, `v2/src/Domenia.Core/ProductInfo.cs`, `v2/tests/Domenia.Tests/PackageLifecycleTests.cs` ;
   - `v2/tools/release-manual-ci.ps1`, `v2/tools/release-guard.py` (deux endroits) ;
   - `v2/tools/verify-manual-packages.py` (table version → date) et `v2/tools/verify-ci-browser-evidence.py` (trois ensembles) ;
   - `v2/tests/tools/test_verify_ci_browser_evidence.py` et `v2/tests/tools/test_verify_manual_packages.py` ;
   - `v2/docs/MISES-A-JOUR.md` ;
   - un nouveau `v2/docs/RECETTE-MANUELLE-V2.1.x.md` ;
   - une entrée datée dans `v2/docs/DECISIONS.md` si une décision change.
3. **Contrats d'opérations** : `python3 -I v2/tools/update-operation-contracts.py --write`, relire le diff, puis relancer
   la commande sans `--write` : elle doit passer.
4. **Contrôles locaux sur le Mac** (non qualifiants) :
   `cd v2/tests/tools && TMPDIR=<dossier temporaire hors /var> python3 -m unittest discover -p "test_*.py"`.
   Sous macOS, `/var` est un lien symbolique : sans `TMPDIR`, une quinzaine de tests échouent avec « Dossier redirigé ».
5. **Relecture** du diff par le Spark, puis vérification de ses remarques une par une.
6. **Intégration** : fusion sans réécriture dans `master`, puis push.
7. **Livraison** : `gh workflow run domenia-v2-livraison.yml -R M4D135/domenia-d120 --ref master -f runner=windows-2025`.
   Récupérer ensuite les artefacts avec `gh run download <run> -R M4D135/domenia-d120 -D <dossier neuf>`. Il y en a
   deux : `domenia-v2-delivery-<sha>-<run>-1` et `domenia-v2-delivery-proofs-<sha>-<run>-1`. Vérifier :
   - `domenia-v2-ci/logs/result.json`, `critical-csharp.log` et `full-csharp.log` (ces journaux sont en UTF-16 :
     les lire avec Python, pas avec grep) ;
   - `domenia-v2-delivery/logs/delivery-result.json`, `browser-evidence.json`, `light-native-login.json` et
     `manual-package-verification.json` ;
   - le SHA-256 du ZIP contre `SHA256SUMS.txt` et `package-release.json` (commit source) ;
   - l'absence du nom du domaine de labo dans chaque fichier du ZIP. Le chercher en Python, en UTF-8 et en UTF-16LE :
     un motif avec octet nul passé par le shell donne de faux résultats.
8. **Banc AD**, seulement si la version touche au démarrage, à la connexion ou au transport AD. Assembler le kit avec
   `python3 -I /Users/david/Documents/Codex/2026-10-26/go/work/domenia-kit/assemble_kit.py` (`-h` pour les arguments ;
   modèle : `domenia-kit/template/`, exemple : `domenia-kit/kit-94851344/`), puis le remettre à David (§ 5).
9. **Publication**, après le « go » écrit de David.
   - Modèle : `domenia-kit/release-v2.1.1/publier.sh` et `notes.md`. Le script vérifie les empreintes et le commit
     distant, puis lance `gh release create … --target <sha> --latest`.
   - Mettre ensuite à jour le README racine, `packs/README.md`, `packs/manifest.json` (avec la version précédente dans
     `previous_releases`), `packs/SHA256SUMS` et `gh repo edit --description`.
   - Vérifier les liens sans compte et l'empreinte d'un téléchargement anonyme.
10. **Clôture** :
    - mettre à jour `v2/REPRISE.md` (en-tête et section datée) et le pousser ;
    - écrire une note KBZA à `--id` stable (exemple : `domenia2-v211-presence-sans-domain-admins-20261109-v1`) ;
    - faire le compte rendu à David.

## 7. Pièges connus

- zsh : un motif comme `--include=*.cs` non cité échoue (« no matches found »). Le mettre entre guillemets.
- Le Mac n'a pas les paquets AD et WMI en cache : on ne peut pas y compiler toute la solution. La compilation qui fait
  foi est celle de la CI.
- Les sorties du Spark sont des brouillons, jamais des preuves. Sur le lot L01, sa relecture du 08/11 avait signalé
  trois défauts infondés.
- Le quota d'artefacts GitHub a déjà été plein. Si un run ne dépose rien, le dire à David avant de supprimer quoi que
  ce soit.
- David travaille souvent à distance (Remote Control). Ses messages sont courts, et les comptes rendus doivent se
  suffire à eux-mêmes.

## 8. Premier message attendu de Codex

Lire les fichiers du § 2, puis vérifier `git -C <clone> status -sb` et `git -C <clone> log --oneline -5` : `master` doit
être à jour avec `origin/master`. Ensuite, répondre à David en cinq lignes au plus :

- l'état compris ;
- le premier sujet attaqué (retour de production 2.1.1 s'il y en a un, sinon TRV-111 et TRV-190) ;
- ce qui attend un geste de David.
