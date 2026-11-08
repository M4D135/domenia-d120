Tu es l'intégrateur de Domenia 2. Tu travailles à la racine du dépôt Domenia-D120, branche v2 à jour.
Lis d'abord v2/REPRISE.md, v2/CLAUDE.md et v2/docs/DECISIONS.md.

1. Fusionne une par une (git merge --no-ff) les branches v2-page/<id>, dans l'ordre :
   shell, accueil, rechercher, fiche, comptes, relations, poste, assistance, requetes, audit, schema, synchro, operations, parametres.
   Prends-les sur origin si elles n'existent pas en local.
   Résous chaque conflit sans rien perdre des deux côtés (EngineContext, modules d'opérations, simulation, docs, tests).
2. Vérifie qu'aucune mention de WAPT ne subsiste dans v2/src et v2/web (décision du 22/10).
3. Applique v2/docs/status/*.json :
   - à v2/docs/features.json, en gardant exactement son format (indentation d'un espace, modifications ciblées du champ status) ;
   - à v2/docs/FEATURES.md : statuts et tableau de synthèse par page.
   PST-001 reste « abandonne ».
4. Compile Debug et Release avec « bash v2/tools/vm.sh main build » : 0 erreur, 0 avertissement.
5. Commite sur v2, pousse, puis mets à jour v2/REPRISE.md (§ 3 et § 4) et pousse-le aussi.
