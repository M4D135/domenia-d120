Tu prends la relève sur Domenia 2 : la réécriture en C# .NET 10 autonome, avec une interface WebView2, de Domenia 1 (outil d'administration Active Directory en PowerShell 5.1 et WPF).

## Repères

- **Dépôt** : /Users/david/Documents/Projets/Domenia-D120, branche v2.
- **Ce qu'il faut faire** : exactement ce que décrit v2/REPRISE.md, qui est la source de vérité.
- **Documents à lire en entier avant toute action** :
  - v2/REPRISE.md, v2/CLAUDE.md, v2/ARCHITECTURE.md ;
  - v2/docs/DECISIONS.md, v2/docs/PLATFORM.md, v2/docs/KIT.md ;
  - v2/docs/WRITES.md, v2/docs/OPERATIONS.md.

## Mission : terminer la vague 2, puis intégrer

### 1. Les 14 écrans, un par un

Ordre : shell, accueil, rechercher, fiche, comptes, relations, poste, assistance, requetes, audit, schema, synchro, operations, parametres.

Pour chaque écran <id> :

- **Arbre de travail** : travaille dans /Users/david/Documents/Projets/Domenia-D120-team/v2-<id> (branche v2-page/<id>, déjà existante).
- **Point de départ** : suis le tableau de REPRISE.md § 4. Si le dernier commit est « wip(...) », vérifie d'abord qu'il compile.
- **Rapport critique** : traite le plus récent, v2/docs/reprise/critiques/<id>-tour<N>.md. Pour chaque fonction manquante :
  - lis sa fiche dans v2/docs/features.json et le code Domenia 1 cité (d1_refs, dans /Users/david/Documents/Projets/Domenia-D120/dev/wad) ;
  - implémente-la fidèlement, côté C# et côté web.
- **Défauts** : corrige chaque défaut de design et de code du rapport.
- **Critique de parité** : refais-la toi-même. Toute fonction de la page <id> dans features.json, sauf le statut « abandonne », doit être réellement réalisée.
- **Statut et tests** : mets à jour v2/docs/status/<id>.json. Écris les tests C# et les scénarios E2E JSON sans les exécuter.
- **Compilation** : « bash v2/tools/vm.sh <id> build » dans la VM Windows, jusqu'à 0 erreur et 0 avertissement.
- **Commit** : commite sur v2-page/<id> avec un message en français, puis pousse la branche.

### 2. L'intégration

Suis v2/docs/reprise/PROMPT-INTEGRATION.md :

- fusion des 14 branches dans v2 ;
- vérification qu'il ne reste aucune mention de WAPT ;
- statuts reportés dans features.json (format inchangé) et dans FEATURES.md ;
- compilation « bash v2/tools/vm.sh main build » en Debug et Release ;
- commit et push.

### 3. Le document de reprise

Mets à jour v2/REPRISE.md (§ 3 et § 4) après chaque écran et après l'intégration, et pousse-le.

## Règles impératives

- **Exigences de David** :
  - autant de fonctions que Domenia 1, voire plus ;
  - interface superbe, animée, propre et bien disposée, cohérente avec l'Accueil et le kit (v2/web/js/kit).
- **C#** :
  - Nullable, avertissements traités comme erreurs ;
  - commentaires en anglais, textes visibles en français soigné.
- **Web** :
  - CSP stricte : aucun style="…", aucun script inline, aucune ressource externe ;
  - règles CSS de l'écran préfixées [data-page="<id>"] ;
  - thèmes clair, sombre et contraste élevé.
- **Écritures** :
  - uniquement par le circuit de WRITES.md : plan, confirmation, reçu, relecture, jamais de rejeu ;
  - lecture seule par défaut, aucun secret.
- **Fichiers partagés** : n'y touche pas depuis un écran (liste dans REPRISE.md § 5).
- **WAPT** : abandonné, supprime toute mention qui reste.
- **VM** :
  - elle sert UNIQUEMENT à compiler, via v2/tools/vm.sh ;
  - pas de capture, pas de lancement de l'application, pas de suite de tests : les tests VM se font à la toute fin, décision de David ;
  - ne compile ni ne lance jamais rien sur le Mac ni sur l'hôte 192.168.1.173 ;
  - ne ferme pas la session de bureau ouverte dans la VM.
- **Quand tu ne sais pas** : n'invente pas. Écris la question dans REPRISE.md et passe à la suite.

Commence par lire les documents, puis annonce ton plan écran par écran et lance-toi.
