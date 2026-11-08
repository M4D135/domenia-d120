# Reprise GitHub — fin physique des SELECT de campagne

Date : 25 octobre 2026. Base du lot : `c134f5fa` sur la branche de reprise dédiée.

## Écarts prouvés

- Les sondes de l’atelier et les SELECT détaillés utilisés par les campagnes Accueil passaient par `WmiWorkstationReader.ReadWorkshopSelectAsync`. Son délai ou annulation rendait la main avant la fin du worker ; le budget natif restait occupé, mais le bail de campagne pouvait être rendu trop tôt.
- L’échec d’une source de `AdQueryWorkshopReader.MeasureAsync` invalidait aussi les sources déjà qualifiées et sauvegardées plus tôt dans cette même demande.

## Corrections

- Option explicite de fin physique pour les deux consommateurs de campagne. Après arrêt logique, `NativeReadCompletion` attend le worker réel sans bloquer le thread UI, observe ses éventuelles fautes tardives et conserve son admission jusqu’à sa terminaison.
- Une lecture native arrêtée ne publie aucune instance non qualifiée. Le refus d’authentification reste traité ; l’annulation de campagne est propagée après la fin physique, avant toute qualification LDAP supplémentaire. Une expiration ne devient pas un succès ni un nouvel essai automatique.
- Les SELECT ordinaires de l’écran Atelier conservent leur détachement rapide ; leurs autres appels de métadonnées et relations ne sont pas élargis par ce lot.
- Les sondes et SELECT effectivement qualifiés puis sauvegardés avant l’arrêt de la source suivante restent conservés avec leurs dates originales. Seules les sources non terminées sont invalidées.
- Recherche des appels directs de campagne Accueil/Recherche : inventaires, console et sondes de parc utilisent les chemins physiques corrigés dans les lots précédents ; aucune collecte de ces campagnes ne passe directement par les lecteurs Poste Events/Software/Probes.

## Fichiers

- `src/Domenia.Inventory/WmiWorkstationReader.Queries.cs`
- `src/Domenia.Ad/Screens/AdQueryWmiReader.cs`
- `src/Domenia.Ad/Screens/AdQueryWorkshopReader.cs`
- `tests/Domenia.Tests/CampaignQueryPhysicalCompletionTests.cs`
- ce rapport.

## Validation

Quatre tests critiques supplémentaires écrits : consommateurs sondes/SELECT réellement raccordés ; deadline et faute native tardive ; conservation de la première source datée quand la suivante s’arrête ; détachement UI ordinaire maintenu. Les fixtures gardent les contrôles de session et de compte avec un compte Remote fictif explicite et un fournisseur CIM injecté, sans contact réel.

Relecture statique et `git diff --check` effectués. Aucune suite exécutée et aucune compilation locale de ce lot. Compilation Windows, tests critiques dans deux VM Windows et recette UI/native restent à vérifier après développement, commit et push. Aucune publication PROD/DEV 2.0.0 ni preuve verte UI n’est revendiquée.
