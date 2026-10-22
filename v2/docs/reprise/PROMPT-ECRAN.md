Tu reprends l'écran « __ID__ » de Domenia 2, la réécriture en C# .NET 10 et WebView2 de Domenia 1 (outil d'administration Active Directory en PowerShell 5.1 et WPF).
Tu es dans l'arbre de travail de la branche v2-page/__ID__.

1. Lis d'abord :
   - v2/REPRISE.md, v2/CLAUDE.md, v2/ARCHITECTURE.md, v2/docs/DECISIONS.md ;
   - v2/docs/PLATFORM.md, v2/docs/KIT.md, v2/docs/WRITES.md, v2/docs/OPERATIONS.md, v2/docs/ops/__ID__.md.
2. Lis le rapport critique le plus récent de cet écran : v2/docs/reprise/critiques/__ID__-tour<N>.md, au N le plus élevé.
   S'il n'en existe pas, fais toi-même la critique :
   - pour chaque fonction de v2/docs/features.json rattachée à la page « __ID__ » (sauf celles au statut « abandonne »), vérifie dans le code C# et web qu'elle est réellement et fidèlement réalisée ;
   - fais la liste de ce qui manque.
3. Regarde « git status » : des modifications non commitées d'un agent précédent peuvent exister. Garde ce qui est bon et termine-le.
4. Implémente chaque fonction manquante ou partielle, fidèlement à Domenia 1 (lis les d1_refs dans /Users/david/Documents/Projets/Domenia-D120/dev/wad), et corrige chaque défaut de design et de code.
5. Règles :
   - interface superbe, animée, propre, cohérente avec l'Accueil et le kit ;
   - CSP stricte, aucun style inline ;
   - écritures uniquement par le circuit de WRITES.md ;
   - lecture seule par défaut ;
   - aucun secret ;
   - textes en français soigné, commentaires en anglais ;
   - ne modifie pas les fichiers partagés listés dans REPRISE.md § 5.
6. Mets à jour v2/docs/status/__ID__.json, les tests C# et les scénarios E2E JSON (écrits, NON exécutés).
7. Compile avec « bash v2/tools/vm.sh __ID__ build » jusqu'à 0 erreur et 0 avertissement.
   Pas de capture, pas de lancement, pas de suite de tests (tests en VM à la toute fin).
8. Une fois le rapport traité, refais toi-même une critique complète de parité :
   - pour chaque fonction de features.json de la page « __ID__ » (sauf « abandonne »), vérifie qu'elle est réellement et fidèlement réalisée ;
   - traite ce qui manque encore, puis recompile.
9. Commite sur la branche v2-page/__ID__ avec un message en français, puis pousse cette branche. Le dernier commit « wip(...) » de la branche peut ne pas compiler : vérifie-le en premier.
