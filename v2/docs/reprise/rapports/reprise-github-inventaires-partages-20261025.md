# Reprise GitHub — admission physique des inventaires partagés

Date : 25 octobre 2026. Défaut identifié en revue de la révision locale `28522316`, dont l’arbre est identique au commit GitHub `fea4c18117d07145d669859f16140739dde03329`. Correctif poussé dans `c134f5fa0af2530523e76370c13b3eb0faddc00f`.

## Écart et correction

`SharedInventoryReads.ReadAsync` détachait immédiatement un abonné annulé. Le dictionnaire
interdisait un second worker sur la même clé, mais la campagne de cet abonné pouvait déjà
libérer son admission globale alors que son inventaire partagé continuait.

L’option explicite `awaitPhysicalCompletion` ajoute le contrat nécessaire aux campagnes :
l’abonné annulé se détache de la progression, demande l’arrêt natif seulement s’il était le
dernier, puis attend la vraie tâche partagée sans token d’annulation. Les autres abonnés
restent actifs. Les appels UI ordinaires conservent leur détachement immédiat.

`AdRelationsReader.InventoryAsync` relaie cette option. Pour une lecture exclusive munie
de callbacks, le lecteur natif attend également sa fin physique lorsqu’une campagne le
demande ; aucun suivi ni repli n’est lancé après arrêt. Le parcours UI de consentement
SYSTEM conserve son comportement existant.

Les inventaires annulés restent datés par leur acquisition, vérifiés par identité locale,
identité native lorsqu’elle a été reçue, compte et session. Leurs sources reçues restent
partielles sans qualification AD finale. La console est retirée ; la valeur destinée à un
autre abonné n’est pas modifiée. Une donnée BIOS non qualifiée n’obtient pas de nouvelle
date utilisable dans la projection du parc.

Les consommateurs Recherche et inventaires des requêtes Accueil demandent cette attente.
La branche inventaire des requêtes termine son enregistrement local avant de propager
l’annulation et avant toute source suivante.

## Tests préparés, non exécutés

Classe `CampaignSharedInventoryTests`, quatre tests :

- Campagne A annulée avec abonné B toujours vivant : A attend, B n’est pas annulé, un seul
  worker existe, A reçoit un partiel daté sans console et B conserve sa réponse native.
- Dernier abonné campagne annulé : attente physique maintenue jusqu’à une faute tardive,
  observée sans succès fabriqué.
- Lecture de campagne exclusive avec callbacks : attente du worker et absence de suivi
  après arrêt.
- Consommateurs Recherche et requêtes Accueil : sauvegarde des mesures reçues avant
  propagation, aucun LDAP supplémentaire, projection incomplète sans console.

`SharedInventoryReadTests` reste pertinent pour vérifier le contrat UI historique :
l’arrêt d’un abonné ordinaire ne bloque pas son retour et n’annule pas les autres.

Relecture statique et `git diff --check` effectués. **Aucun test ni compilation exécuté
pour ce correctif par cet agent.** La validation critique des deux VM Windows et la recette
UI/native demeurent non vérifiées à ce stade.

## Compilation Windows du correctif poussé

Commit `c134f5fa0af2530523e76370c13b3eb0faddc00f` : [run GitHub Actions 40216313386](https://github.com/M4D135/domenia-d120/actions/runs/40216313386), job `121238089184`. Journaux lus : Debug (17:26:09 UTC) et Release (17:26:49 UTC le 25/10/2026) réussis, **0 avertissement, 0 erreur**. Aucun test exécuté. Le correctif SELECT Atelier ultérieur et la recette des deux VM ne font pas partie de cette preuve.
