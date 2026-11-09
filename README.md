# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.0

Dernière version : **2.1.0**, construite depuis [`94851344`](https://github.com/M4D135/domenia-d120/commit/948513449f014a132d610456356d1c7b708d925b). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.0_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.0/Domenia_2.1.0_PROD-LIGHT_Windows-x64.zip) (80 Mo) |
| **Sources** | [Sources exactes de 2.1.0](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.0.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.0/SHA256SUMS.txt) |

[Release v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) · [provenance du pack](packs/README.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.1.0.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `53f6a967d72879e5b284f9e29bfa097774c35523e5c4d3c52b123efc38a488a3`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.0.8 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Conserver la version précédente localement.

## Nouveautés de 2.1.0

- **22 lots de parité** de l’audit du 31 octobre : annuaire et postes, connexion et comptes, moteur, ateliers de requêtes, données locales, collecte, journal technique, démarrage et livraison, interface.
- **Fermeture.** Sur un poste membre d’aucun domaine, la fermeture ne signale plus « Fermeture incomplète ».
- **Mises à jour.** Paramètres → Mises à jour ne lit plus qu’un dossier de diffusion ou un ZIP local, avec `SHA256SUMS.txt`. GitHub n’est plus consulté.

## Validation de 2.1.0

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/42534422081) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 025 tests, dont les 1 583 critiques ;
- 218 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

Sur une VM Windows 11 de test, le contrôle du pack réussit : empreintes, extraction neuve, identité du pack et détection de WebView2 Evergreen 140.0.3485.54 (`--check-only`). La connexion à un annuaire n’a pas encore été rejouée sur ces octets. Aucune écriture AD n’a été exécutée. Ce n’est ni une recette utilisateur ni une validation sur le domaine de production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 avec sa seule dernière version : les packs 2.0.x ne sont plus publiés.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
