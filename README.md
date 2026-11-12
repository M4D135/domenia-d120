# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.6

Dernière version : **2.1.6**, construite depuis [`3869e60f`](https://github.com/M4D135/domenia-d120/commit/3869e60ffca2512c056567545863ae146595e410). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.6_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.6/Domenia_2.1.6_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.6](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.6.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.6/SHA256SUMS.txt) |

[Release v2.1.6](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.6) · [provenance du pack](packs/README.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.1.6.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `3d5ec57e326123a60c46042cffc52c006dac630a9839d505e5f5d8c8b0709b13`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.5 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Conserver la version précédente localement.

## Nouveautés de 2.1.6

- **Configuration par défaut écrite sur place**, comme GLPI Pilot. Paramètres > Configuration à diffuser > « Définir comme configuration par défaut » écrit un seul fichier, `wad/Domenia.settings.seed.json`, dans le dossier du Domenia ouvert. Jusqu’en 2.1.5, ce bouton fabriquait une copie complète du pack (nouveau ZIP, nouvelles empreintes). Le ZIP officiel, le manifeste et les binaires restent intacts : il suffit de diffuser le dossier.
- **Démarrage et mises à jour.** Le contrôle du pack admet ce fichier à sa place, hors manifeste, et une mise à jour le conserve.
- **Remplacement prudent.** Un fichier déjà présent est d’abord sauvegardé dans les exports. Réécrire les mêmes choix ne change rien : le fichier reste identique à l’octet.
- **Profils.** Un profil vierge reçoit la configuration au démarrage, sans question. Un profil existant choisit de la remplacer ou de garder ses réglages. Le profil qui l’a définie ne se la voit pas reproposer.
- **Copies préparées avant 2.1.6.** Elles restent valides et se mettent à jour sans perdre leur configuration. Pour la redéfinir sur place, extraire le ZIP officiel dans un nouveau dossier.

Aucun changement de lecture des postes, d’inventaire ou d’AD. Les correctifs de 2.1.5 (lectures WinRM, logiciels installés, affichage sans accélération graphique) sont conservés ; voir les [mises à jour](v2/docs/MISES-A-JOUR.md).

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

## Validation de 2.1.6

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/43213255629) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 078 tests, dont les 1 650 critiques ;
- 227 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

Banc du 12 novembre sur un poste de test, en deux passages. Le premier a confirmé l’écriture sur place, le redémarrage et la réception par un profil vierge ; il a fait corriger trois défauts de la page. Le second, sur un kit de la même source produit avant les seules retouches de documentation, est conforme : écriture, quatre réécritures de suite, redémarrage sans refus ni proposition. Aucune écriture AD n’a été exécutée. La mise à jour d’une copie préparée avant 2.1.6 et un dossier en lecture seule sont couverts par les tests, non observés sur banc. La recette utilisateur complète reste à effectuer ; la qualification CI ne constitue pas une validation en production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases v2.1.0 à v2.1.4 ont été retirées le 12/11/2026 ; la [release v2.1.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.5) reste disponible.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
