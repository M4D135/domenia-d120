# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.8

Dernière version : **2.1.8**, construite depuis [`a50e8752`](https://github.com/M4D135/domenia-d120/commit/a50e8752fa0a816870f54b8c4abf8d895473880f). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.8_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.8/Domenia_2.1.8_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.8](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.8.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.8/SHA256SUMS.txt) |

[Release v2.1.8](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.8) · [provenance du pack](packs/README.md) · [recette](v2/docs/RECETTE-MANUELLE-V2.1.8.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `32b3a1acc2c273d8f808d35f9096d3cc07b047970fae7378ecdfa690ac5bbd68`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.7 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Une installation 2.1.7 se met à jour vers 2.1.8 depuis Paramètres ou par `livraison` ; le passage 2.1.7 → 2.1.8 a été observé abouti par `livraison`. La recette de 2.1.8 ne part plus de 2.1.5 ni de 2.1.6 ; pour ces versions, extraire ce ZIP dans un nouveau dossier reste le chemin sûr. Conserver la version précédente localement.

## Nouveautés de 2.1.8

- **« Tout actualiser » va de nouveau au bout.** Jusqu’en 2.1.7, il suffisait d’un compte ordinateur sans nom DNS cohérent dans l’OU pour arrêter tout le relevé de présence, puis l’inventaire (« Identité du compte ordinateur absente, modifiée ou incohérente ; lecture écartée »). C’est le cas d’un compte pré-créé sans nom DNS ou d’un poste renommé dont le nom DNS n’a pas suivi.
- **Compte sans nom DNS cohérent.** Il reçoit une réponse définitive, « Nom de poste invalide », avec son motif. Il n’est pas contacté et le relevé continue ; le journal nomme ces postes.
- **Compte modifié depuis la préparation du relevé.** Il est écarté seul, sans donnée attribuée, et compté dans le journal, qui invite à relire l’annuaire.

Aucun changement d’interface, d’inventaire, d’écriture AD ni de commande de maintenance. Les correctifs de 2.1.7 (mises à jour, commandes `livraison`) et la configuration par défaut écrite sur place (2.1.6) sont conservés ; voir les [mises à jour](v2/docs/MISES-A-JOUR.md).

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

## Validation de 2.1.8

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/43256107229) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 082 tests, dont les 1 654 critiques, avec un test qui reproduit le cas signalé (poste valide, compte pré-créé, poste renommé et compte modifié dans le même relevé) ;
- 227 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

[Recette des binaires](https://github.com/M4D135/domenia-d120/actions/runs/43261204475) sur un runner Windows hébergé jetable, avec ce ZIP exact et le ZIP 2.1.7 retéléchargé depuis sa release : 13 étapes, aucun échec. La mise à jour 2.1.7 → 2.1.8 est confirmée par le vrai contrôle de santé, et la configuration écrite sur place est gardée à l’octet. La restauration vers 2.1.7 garde le fichier, et 2.1.7 démarre.

**Limites.** La correction n’a pas été observée sur un vrai domaine, et 2.1.8 n’a pas été repassée sur le banc administrateur. La mise à jour lancée depuis Paramètres, qui utilise le même contrôle de santé, n’a pas été cliquée. La recette utilisateur complète reste à effectuer ; la qualification CI ne constitue pas une validation en production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases v2.1.0 à v2.1.6 ont été retirées le 12/11/2026 : seule la dernière version est publiée, v2.1.7 reste en ligne jusqu’à décision. Leurs sources restent dans l’historique de `master`.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
