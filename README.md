# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.1

Dernière version : **2.1.1**, construite depuis [`7627bd1e`](https://github.com/M4D135/domenia-d120/commit/7627bd1e50d9b72a255f98b8d980f4496cb59397). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.1_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.1/Domenia_2.1.1_PROD-LIGHT_Windows-x64.zip) (80 Mo) |
| **Sources** | [Sources exactes de 2.1.1](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.1.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.1/SHA256SUMS.txt) |

[Release v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) · [provenance du pack](packs/README.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.1.1.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `85d795d75b332a9008de14c235ca81b788d44a4006e510e86c7f6c568689f8b2`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.0 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Conserver la version précédente localement.

## Nouveautés de 2.1.1

- **Postes en ligne.** Mesurer la présence ne demande plus de compte d’administration : le ping et le DNS n’envoient aucun identifiant au poste. Cela vaut pour l’Accueil, la fiche, le poste et Rechercher.
- **Lectures distantes.** Avec l’identité de la session Windows, l’inventaire, la console, les sondes, les journaux, la fiche, Rechercher et les requêtes sont tentés sans contrôle préalable de Domain Admins. Domenia ne manipule aucun mot de passe : le poste accepte si le compte y est administrateur. Sinon, le refus est compté pour ce poste et la campagne continue.
- **Inchangé.** Un compte saisi et toute écriture distante gardent leur validation.

2.1.0 avait apporté les 22 lots de parité de l’audit du 31 octobre, la fermeture sans avertissement hors domaine et des mises à jour lues seulement depuis un dossier de diffusion ou un ZIP local.

## Validation de 2.1.1

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/42641992867) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 028 tests, dont les 1 586 critiques ;
- 218 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

Le correctif n’a pas encore été exercé sur un domaine avec un compte hors Domain Admins. Pour 2.1.0, le ZIP publié a passé le 09/11 sur une VM jointe au domaine de test le contrôle du pack puis la connexion native : parcours hors connexion, puis connexion avec l’identité de la session Windows et Accueil connecté, fermetures propres. 2.1.1 ne modifie ni le démarrage ni la connexion. Aucune écriture AD n’a été exécutée. Ce n’est ni une recette utilisateur ni une validation sur le domaine de production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. La [release v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) reste disponible.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
