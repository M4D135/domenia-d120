# Master prompt — relève de Domenia 2 par Codex

Tu reprends **Domenia 2** et tu le termines entièrement. Domenia 2 est la réécriture en C# .NET 10 LTS autonome, avec une interface HTML dans WebView2, de Domenia 1, outil d'administration Active Directory en PowerShell 5.1 et WPF.

## 0. Où tu es

- **Dépôt** : `/Users/david/Documents/Projets/Domenia-D120`, sur GitHub `M4D135/domenia-d120`, branche **`v2`**.
- **Domenia 1** : dans `dev/` (branche `master`), en lecture seule. C'est la référence de parité.
- **À lire en entier avant toute action** :
  - `v2/REPRISE.md` : état, § 0 en premier, puis § 4 bis et § 5 ;
  - `v2/CLAUDE.md`, `v2/ARCHITECTURE.md` ;
  - `v2/docs/DECISIONS.md` : toutes les décisions datées de David, à respecter ;
  - `v2/docs/PLATFORM.md`, `KIT.md`, `WRITES.md`, `OPERATIONS.md`, `SIMULATION.md`, `E2E.md`, `CAPTURE.md` ;
  - `v2/docs/features.json` et `FEATURES.md` : 993 fonctions de Domenia 1 avec leur statut ;
  - `v2/docs/reprise/SUIVI-SPARK.md` sur la branche `v2-spark`.
- **Préversion déjà publiée** : release `v2.0.0-preview.1` (commit `5b27d58`).

## 1. Première chose : arrêter le Spark et récupérer son travail

Un démon fait travailler le Spark sur 7 tâches. Il s'agit de `../Domenia-D120-team/_pilotage/spark/auto.py`, avec son état dans `state.json`, son journal dans `auto.log`, les rapports `verify-<id>.txt` et la branche d'intégration `v2-spark`. Tu reprends tout seul, donc :

1. Arrête-le, ainsi que ses OpenCode :

```bash
pkill -f auto.py
pkill -f "opencode run --auto -m spark"
pkill -f "opencode run --auto -m opencode/deepseek"
```

2. Pour chaque arbre `../Domenia-D120-team/sp-<id>` (branche `spark/<id>`) :
   - lis son suivi `v2/docs/reprise/spark/<id>.md` et ses commits ;
   - commite ce qui traîne ;
   - garde le bon travail, jette le mauvais. Le Spark peut se tromper, relis tout.
3. Les 7 tâches sont décrites dans `../Domenia-D120-team/_pilotage/spark/tasks/*.md` :

| Tâche | Contenu |
|---|---|
| 01 | Derniers échecs E2E en simulation (124/137 au dernier passage) |
| 02 | Mode annuaire réel : Accueil et Rechercher |
| 03 | Mode annuaire réel : Fiche et Comptes, avec les écritures LDAP réelles et le coffre Windows CPT-017 |
| 04 | Mode annuaire réel : Utilisateurs et postes, et Poste (CIM/WMI, ping) |
| 05 | Mode annuaire réel : Requêtes, Audit, Schéma et Comptes machine |
| 06 | Base locale SQLite par `winsqlite3.dll`, compatible avec le schéma 11 de Domenia 1, et écran Synchronisation |
| 07 | Mode annuaire réel : Opérations, Assistance et Paramètres |

## 2. Ta mission jusqu'au bout

1. **Terminer les 7 tâches** ci-dessus, sur `v2`, ou sur des branches que tu fusionnes dans `v2`.
2. **Traiter les partiels et les « à faire » restants** de `features.json` (hors `abandonne`), y compris les suites d'intégration listées dans `REPRISE.md` § 4 :
   - les branchements de la coque : CPT-001, CPT-012, REL-029, ASS-006, ASS-012, MAC-002, OPE-014 et OPE-015 ;
   - les doublons d'écritures entre Fiche et Comptes, à unifier.
3. **Compiler** Debug et Release, sans erreur ni avertissement :

```bash
bash v2/tools/vm.sh main build --config both
```

4. **Lancer la suite C#** jusqu'à 100 % de réussite :

```bash
bash v2/tools/vm.sh main test
```

5. **Lancer l'E2E en simulation** jusqu'à 137/137, voire plus :

```bash
bash v2/tools/vm.sh main e2e --mode simulation --out e2e-out
```

6. **Faire l'E2E en mode annuaire** sur le labo `cnamts.local`, dans la session de bureau ouverte de la VM : `--mode annuaire`.
   - David autorise les écritures AD réelles **uniquement dans `OU=Domenia-Tests`**. Crée-la, avec ses comptes, groupes et postes de test.
   - Corrige tout ce qui échoue.
7. **Mettre à jour** les statuts dans `features.json` (format inchangé : indentation d'un espace, modifications ciblées) et `FEATURES.md`, ainsi que `REPRISE.md`. Commite et pousse `v2` régulièrement.
8. **Livrer** :
   1. `bash v2/tools/vm.sh main publish --zip` ;
   2. récupère le ZIP avec `scp domenia-vm:C:/DomeniaDev/out/main/Domenia.zip …` ;
   3. fabrique le pack DEV avec `git archive` de `v2/` ;
   4. calcule les SHA-256 ;
   5. `gh release create v2.0.0` avec `Domenia2-PROD-<commit>.zip`, `Domenia2-DEV-<commit>.zip` et `SHA256SUMS.txt`.

## 3. Exigences de David (non négociables)

- **Parité** : autant de fonctions que Domenia 1, voire plus. Rien ne disparaît sans décision écrite. Seule exception à ce jour : WAPT (PST-001), abandonné, à ne jamais réintroduire.
- **Interface** : superbe, « web 4.0 », très animée mais propre et bien disposée, cohérente avec l'Accueil et le kit `v2/web/js/kit`. Thèmes clair, sombre et contraste élevé.
- **Portabilité** : pack autonome, à dézipper et lancer, rien à installer.
- **Mode simulation** : il doit rester intact (annuaire fictif `example.local`, écritures en mémoire seulement).
- **Accueil** : pas de prénom ; le compte d'administration s'affiche en puce.

## 4. Règles techniques

- **C#** :
  - Nullable activé, avertissements traités comme erreurs, `AnalysisLevel latest` : **0 avertissement** ;
  - commentaires en anglais, textes visibles en français soigné.
- **Web** :
  - CSP stricte : aucun `style="…"`, aucun script inline, `connect-src 'none'`, aucune ressource externe ;
  - modules ES natifs ;
  - un écran = `web/js/pages/<id>.js` et `web/css/pages/<id>.css`, avec des règles préfixées `[data-page="<id>"]`.
- **Écritures** :
  - uniquement par le circuit de `WRITES.md` : plan, jeton à usage unique, confirmation par saisie du nom, reçu, relecture ;
  - jamais de rejeu automatique ;
  - mots de passe en `SecureString` jusqu'à l'API Windows.
- **Sécurité** :
  - lecture seule par défaut ;
  - aucun accès réseau sans geste explicite ;
  - jamais tout le domaine sans garde ;
  - aucun secret dans le dépôt, un journal ou une ligne de commande.
- **Où compiler et lancer** :
  - **dans la VM Windows uniquement**, par `v2/tools/vm.sh` (verrou exclusif ; VM `DOMENIA-FIRSTRUN-20261020`, alias SSH `domenia-vm`, 4 vCPU maximum) ;
  - **jamais** sur le Mac, jamais sur l'hôte 192.168.1.173 ;
  - ne ferme pas la session de bureau `CNAMTS\Administrateur` ouverte sur la console de la VM : les E2E s'y jouent ;
  - disque de la VM limité : supprime les vieux dossiers `C:\DomeniaDev\src\<lot>` et `out\<lot>` inutiles.
- **Interdictions** : n'affaiblis jamais un test ou une garde pour faire passer quelque chose ; ne touche pas à `dev/` (Domenia 1).
- **Commits** : en français, poussés sur `v2` à chaque étape qui compile.
- **Suivi** : tiens `v2/REPRISE.md` à jour, surtout la § 0, pour qu'une autre relève puisse reprendre.
- **En cas de doute** : n'invente pas. Écris la question dans `REPRISE.md`, prends la décision la plus sûre et continue.

Commence par lire, arrête le démon, fais l'inventaire des branches `spark/*`, annonce ton plan, puis va jusqu'à la release `v2.0.0`.
