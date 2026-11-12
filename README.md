# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.7

Dernière version : **2.1.7**, construite depuis [`e2a7ed46`](https://github.com/M4D135/domenia-d120/commit/e2a7ed467141a933e784c97ff747e72b729b5aaf). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.7_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.7/Domenia_2.1.7_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.7](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.7.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.7/SHA256SUMS.txt) |

[Release v2.1.7](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.7) · [provenance du pack](packs/README.md) · [recette](v2/docs/RECETTE-MANUELLE-V2.1.7.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `ec8a8d2f6f03eb197a16cde4e6c5d8ff27e3fce157bde63bbf1439c797340ca2`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.6 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Une mise à jour vers 2.1.7 est conduite par l’assistant et le contrôle de santé de 2.1.7, déjà corrigés : depuis 2.1.5 et 2.1.6, elle a été observée aboutie par `livraison`. Conserver la version précédente localement.

## Nouveautés de 2.1.7

- **Mises à jour de nouveau abouties.** Le contrôle de santé du nouveau code annulait sa propre page de vérification. Chaque mise à jour, depuis Paramètres comme en ligne de commande, revenait donc aux anciens binaires, sans donner de raison. Le contrôle charge désormais cette page et refuse toute autre navigation. Un retour automatique indique sa cause.
- **Commandes de maintenance.** `Domenia.exe livraison …` (aperçu et application d’une mise à jour, reprise, restauration, désinstallation) répond de nouveau ; depuis 2.0.8, ces commandes répondaient « Commande inconnue ».
- **Restauration protégée.** Une restauration vers une version antérieure à 2.1.6 est refusée, avant toute modification, tant qu’une configuration par défaut est écrite sur place : ces versions ne démarreraient pas avec elle. Le message nomme le fichier à déplacer.
- **Contrôle d’un fichier de configuration.** `Domenia.exe --check-settings-seed` rend le code 2 pour un fichier invalide, au lieu de s’arrêter sur une erreur.

Aucun changement d’interface, de lecture des postes, d’inventaire ou d’AD. La configuration par défaut écrite sur place (2.1.6) et les correctifs de 2.1.5 sont conservés ; voir les [mises à jour](v2/docs/MISES-A-JOUR.md).

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

## Validation de 2.1.7

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/43231233101) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 081 tests, dont les 1 653 critiques ;
- 227 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

[Recette des binaires](https://github.com/M4D135/domenia-d120/actions/runs/43241745675) sur un runner Windows hébergé jetable, avec ce ZIP exact et les ZIP 2.1.5 et 2.1.6 retéléchargés depuis leurs releases : 21 étapes, aucun échec. Les mises à jour 2.1.5 → 2.1.7 et 2.1.6 → 2.1.7 sont confirmées par le vrai contrôle de santé, et la configuration écrite sur place est gardée à l’octet. La restauration vers 2.1.5 est refusée tant que le fichier est là, puis aboutit après son déplacement. La restauration vers 2.1.6 garde le fichier.

**Limites.** 2.1.7 n’a pas été repassée sur le banc administrateur : son interface est celle de 2.1.6, qualifiée sur banc le 12 novembre. La mise à jour lancée depuis Paramètres, qui utilise le même contrôle de santé, n’a pas été cliquée. La recette utilisateur complète reste à effectuer ; la qualification CI ne constitue pas une validation en production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases v2.1.0 à v2.1.4 ont été retirées le 12/11/2026 ; les releases [v2.1.6](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.6) et [v2.1.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.5) restent disponibles.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
