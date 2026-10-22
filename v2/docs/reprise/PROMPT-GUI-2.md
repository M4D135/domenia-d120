Tu prends la relève sur Domenia 2, la réécriture en C# .NET 10 autonome avec une interface WebView2 de Domenia 1 (outil d'administration Active Directory en PowerShell 5.1 et WPF).

## Repères

- Dépôt : /Users/david/Documents/Projets/Domenia-D120.
- Sources de Domenia 1, en lecture seule : dev/wad.
- À lire en entier avant toute action :
  - v2/REPRISE.md, surtout la § 0 ;
  - v2/CLAUDE.md, v2/docs/DECISIONS.md, v2/docs/PLATFORM.md, v2/docs/OPERATIONS.md, v2/docs/WRITES.md.

## Partage du travail avec le Spark (à respecter)

Un démon fait travailler le Spark en parallèle (`../Domenia-D120-team/_pilotage/spark/auto.py`, suivi dans `v2/docs/reprise/SUIVI-SPARK.md` sur la branche `v2-spark`).

- **Ne touche pas aux tâches du Spark** : 01 (scénarios E2E), 02 (Accueil et Rechercher), 03 (Fiche et Comptes), 04 (Relations et Poste).
- **Ne touche pas aux branches `spark/*` ni à `v2-spark`.**

## TA MISSION 1 : trois tâches, une branche chacune

Pour chacune des trois tâches, crée ta branche et ton arbre :

```bash
git worktree add -b gui/<id> ../Domenia-D120-team/gui-<id> origin/v2-spark
```

1. **gui/05-ad-requetes-audit-schema** : mode annuaire réel des écrans Atelier de requêtes (collecte bornée), Audit AD, Schéma et Comptes machine.
   - Lecteurs dans v2/src/Domenia.Ad/Screens/, selon les sections « Mode annuaire » de v2/docs/ops/requetes.md, audit.md et schema.md.
   - Requêtes LDAP paginées et bornées, jamais tout le domaine sans garde.
   - Tests unitaires sans AD réel.
2. **gui/06-store-synchro** : base locale réelle.
   - v2/src/Domenia.Store en SQLite par winsqlite3.dll (P/Invoke, aucune dépendance), compatible avec le schéma 11 de Domenia 1 (dev/wad/modules/Domenia-Store*, Domenia-DirectoryStore*, Domenia-Storage*), migration sans perte.
   - Brancher l'écran Synchronisation (v2/docs/ops/synchro.md) et les fonctions « partiel » qui attendaient Domenia.Store (v2/docs/status/*.json).
   - Tests unitaires sur une base temporaire.
3. **gui/07-ops-assist-param** : mode annuaire réel des écrans Opérations, Assistance et Paramètres (v2/docs/ops/operations.md, assistance.md, parametres.md).
   - Exports : décision du 22/10, écrire = LocalWrite et ouvrir = Local.
   - Tests unitaires.

Pour chaque tâche :

- Compile avec `bash v2/tools/vm.sh g<numéro> build --config both` : 0 erreur, 0 avertissement.
- Lance la suite C# avec `bash v2/tools/vm.sh g<numéro> test` : tout doit réussir.
- Tiens le suivi `v2/docs/reprise/gui/<id>.md` à jour : fait, reste, questions.
- Commite et pousse ta branche gui/<id> à chaque étape qui compile.

## TA MISSION 2 : quand le Spark a fini

Le Spark a fini quand `SUIVI-SPARK.md` n'affiche plus aucune tâche en `running` ni en `pending`. Arrête le démon s'il tourne encore (`pkill -f "python3 auto.py"`), puis :

1. Sur `v2`, fusionne :
   - `origin/v2-spark`, qui contient les tâches du Spark validées ;
   - tes trois branches gui/* ;
   - chaque branche spark/* restée en échec ou en conflit qui contient du bon travail, après relecture.
2. Résous les conflits sans rien perdre.
3. Compile Debug et Release avec `bash v2/tools/vm.sh main build --config both`. La suite C# doit être à 100 %.
4. Lance l'E2E en simulation : `bash v2/tools/vm.sh main e2e --mode simulation --out e2e-out`. Corrige jusqu'à tout vert.
5. Lance l'E2E en mode annuaire sur le labo `cnamts.local`, dans la session de bureau ouverte de la VM. Les écritures sont autorisées par David, uniquement dans `OU=Domenia-Tests`, que tu crées si elle manque. Corrige ce qui échoue.
6. Mets à jour `v2/docs/features.json`, `FEATURES.md` et `REPRISE.md`, puis commite et pousse `v2`.
7. Publie le pack :
   - `bash v2/tools/vm.sh main publish --zip` ;
   - rapatrie le ZIP (`scp` via `domenia-vm`) ;
   - fabrique le pack DEV avec `git archive` de `v2/` ;
   - calcule les SHA-256 ;
   - crée la release `gh release create v2.0.0` avec les deux ZIP et `SHA256SUMS.txt`.

## Règles impératives

- Autant de fonctions que Domenia 1, voire plus. Interface soignée, cohérente avec l'Accueil et le kit.
- C# :
  - avertissements traités comme erreurs ;
  - commentaires en anglais ;
  - textes visibles en français soigné.
- Web : CSP stricte, aucun style inline.
- Écritures uniquement par le circuit de WRITES.md. Lecture seule par défaut. Aucun secret.
- VM uniquement par v2/tools/vm.sh. Rien ne se compile ni ne se lance sur le Mac ou sur l'hôte. Ne ferme pas la session de bureau de la VM.
- N'affaiblis jamais un test ou une garde pour faire passer quelque chose.
- Quand tu ne sais pas, écris la question dans `REPRISE.md` et continue.

Commence par lire, annonce ton plan, puis lance-toi.
