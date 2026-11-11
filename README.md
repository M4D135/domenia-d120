# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.5

Dernière version : **2.1.5**, construite depuis [`9282893d`](https://github.com/M4D135/domenia-d120/commit/9282893d6e5bc4409ca2f4e369c57f37a7f5bfb7). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.5_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.5/Domenia_2.1.5_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.5](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.5.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.5/SHA256SUMS.txt) |

[Release v2.1.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.5) · [provenance du pack](packs/README.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.1.5.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `d435e21033ca144bf5ba31c43aa5ce76caa538fa8f9cc19faa1d70a925541a9a`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.4 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Conserver la version précédente localement.

## Nouveautés de 2.1.5

- **Lectures WinRM.** Le choix « CIM / WinRM » ouvre de nouveau la session : en 2.1.4, chaque source échouait en 0x80070057. Les réponses WinRM sont lues comme les lectures DCOM (fragments XML, dates, sessions ouvertes, tableaux).
- **Poste sans WinRM** (cas par défaut de Windows 11). La première source rend « Injoignable » avec son code (0x80338012), les suivantes aussitôt, sans nouvelle tentative de connexion ni source « Interrompu ».
- **Logiciels installés.** Une valeur de registre absente n’écarte plus le programme : en 2.1.4, aucun logiciel n’était listé sur le poste de banc. « Site AD » lit de nouveau ses deux valeurs.
- **Interface sans accélération graphique** (machine virtuelle sans carte graphique, certaines sessions à distance). Les animations en boucle s’arrêtent après un passage : au repos, elles occupaient jusqu’à 1,7 des 2 cœurs du poste de banc et ralentissaient la lecture du poste. Le choix Animations est conservé ; Paramètres > Apparence l’indique.
- **Lecture plus rapide.** Le démarrage du processus de lecture est préparé hors délai, sans contact avec le poste : la première source passe de 9,5 s à 1,2 s, et l’inventaire rapide lit les 27 sources en 26,4 s sur le poste de banc (19 sur 27 avant le plafond de 55 s en 2.1.4).
- **Codes et démarrage.** Un poste injoignable affiche son code, en DCOM comme en WinRM. Au démarrage, la configuration du pack n’est plus refusée quand un réglage attend son enregistrement.

**Limite connue.** Une lecture WinRM réussie n’a pas été observée sur le poste de banc, qui n’a pas d’écouteur WinRM ; elle est couverte par les tests et un rejeu sur runner hébergé, et reste à vérifier sur un poste où WinRM est actif. Le mode Automatique garde l’ordre DCOM d’abord.

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

2.1.1 avait supprimé le contrôle préalable de Domain Admins pour le ping et les lectures distantes avec l’identité de la session Windows. Un compte saisi et toute écriture distante gardent leur validation.

## Validation de 2.1.5

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/43116714568) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 075 tests, dont les 1 647 critiques ;
- 225 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

Banc du 11 novembre sur un poste de test, avec un kit de la même source produit avant les seules retouches de documentation : inventaire rapide en Automatique, 27 sources sur 27 par DCOM en 26,4 s, dont les logiciels installés ; « CIM / WinRM » sur un poste sans écouteur, 0 sur 27 en 5,6 s sans source « Interrompu ». Aucune écriture AD n’a été exécutée. La recette utilisateur complète, notamment avec un compte hors Domain Admins, reste à effectuer ; la qualification CI ne constitue pas une validation en production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases [v2.1.4](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.4), [v2.1.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.3), [v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2), [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
