# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.3

Dernière version : **2.1.3**, construite depuis [`65daf42f`](https://github.com/M4D135/domenia-d120/commit/65daf42f3637eeea2f60e0a2ba150bef686a37a3). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.3_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.3/Domenia_2.1.3_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.3](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.3.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.3/SHA256SUMS.txt) |

[Release v2.1.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.3) · [provenance du pack](packs/README.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.1.3.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `583f1de66d0b2e2385291224472b9bd784180ba781302390683bd38a20e6a74c`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.2 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Conserver la version précédente localement.

## Nouveautés de 2.1.3

- **Actualisation stable.** Les cartes de progression gardent leurs éléments et le focus pendant les mises à jour ; elles ne clignotent plus à chaque seconde.
- **Données et cache.** La consultation utilise un inventaire léger et ne déclenche plus le contrôle complet de purge sur les cellules volumineuses. Les vérifications des plans de modification restent intactes.
- **Mises à jour lisibles.** Le texte des encadrés utilise la largeur de la carte en production comme en démonstration.
- **Version courte.** L’interface affiche **2.1.3**. L’identité de compilation reste disponible pour les contrôles techniques.

Les comparaisons de populations, les contrats de sondes et la clôture de parité de 2.1.2 sont conservés.

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

2.1.1 avait supprimé le contrôle préalable de Domain Admins pour le ping et les lectures distantes avec l’identité de la session Windows. Un compte saisi et toute écriture distante gardent leur validation.

## Validation de 2.1.3

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/42772371612) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 046 tests, dont les 1 610 critiques ;
- 221 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

La recette sur domaine réel, notamment avec un compte hors Domain Admins, et les mesures de performances réelles restent à effectuer. Aucun ancien LOGIN de banc n’est appliqué à cette révision. Aucune écriture AD n’a été exécutée. La qualification CI ne constitue pas une recette utilisateur ni une validation en production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases [v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2), [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
