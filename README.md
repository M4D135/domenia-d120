# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.2

Dernière version : **2.1.2**, construite depuis [`c2e5edb1`](https://github.com/M4D135/domenia-d120/commit/c2e5edb1fe1841821a02e27e2014a6774015c82e). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.2_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.2/Domenia_2.1.2_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.2](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.2.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.2/SHA256SUMS.txt) |

[Release v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2) · [provenance du pack](packs/README.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.1.2.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `b4fd5a59f571db88ae60a4fe612e44bf58230b28c1c1e0302cc79a88b5082a2f`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.1 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Conserver la version précédente localement.

## Nouveautés de 2.1.2

- **Comparaisons de populations.** Une description absente reste inconnue. L’apparition ou la disparition d’un score donne une comparaison limitée avec sa raison ; sa seule disponibilité ne prouve ni stabilité ni amélioration.
- **Contrats des sondes.** Les contrôles de comptes et groupes ignorent la casse, les filtres de comptes locaux doivent réellement restreindre la lecture et les sous-espaces interdits sont refusés. Lecture CIM seule, aucune méthode ni écriture, collecte lourde explicitement demandée.
- **Réglages effectifs.** PAR-046 est clôturé sur les raccordements L16/L02 et leurs tests existants. Le délai des commandes distantes est appliqué par appel natif, de 1 à 300 secondes (défaut 10), sans terminer artificiellement un appel COM ni déclencher de rejeu.

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

2.1.1 avait supprimé le contrôle préalable de Domain Admins pour le ping et les lectures distantes avec l’identité de la session Windows. Un compte saisi et toute écriture distante gardent leur validation.

## Validation de 2.1.2

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/42701363001) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 043 tests, dont les 1 601 critiques ;
- 218 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

La recette sur domaine réel, notamment avec un compte hors Domain Admins, et les mesures de performances réelles restent à effectuer. Aucun ancien LOGIN de banc n’est appliqué à cette révision. Aucune écriture AD n’a été exécutée. La qualification CI ne constitue pas une recette utilisateur ni une validation en production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
