# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.4

Dernière version : **2.1.4**, construite depuis [`6d8dbfd7`](https://github.com/M4D135/domenia-d120/commit/6d8dbfd75141d3cdb6f4ffda4464c3ae868c1b80). Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.4_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.4/Domenia_2.1.4_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.4](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.4.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.4/SHA256SUMS.txt) |

[Release v2.1.4](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.4) · [provenance du pack](packs/README.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.1.4.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `21ef429327e063bd15d80baf4257d810617c8b3a3da79dca68b6a031e8c2385a`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données ne change pas : une base de 2.0.5 à 2.1.3 s’ouvre telle quelle. Un poste en PROD 2.0.8 doit extraire ce ZIP à la main, car une mise à jour ne change pas d’édition. Conserver la version précédente localement.

## Nouveautés de 2.1.4

- **Inventaire en mode Automatique.** Les lectures passent d’abord par WMI / DCOM, comme Domenia 1. Un poste injoignable en DCOM est relu une seule fois par WinRM s’il est autorisé. Le choix « CIM / WinRM » reste exclusif ; les modifications distantes gardent leur transport.
- **Une source lente n’arrête plus l’inventaire.** Elle est marquée « Interrompu » et les suivantes sont lues. Une requête restée sans réponse au-delà de son délai arrête son processus de lecture sans rejeu ; un processus neuf lit les sources suivantes, deux fois au plus. Pilotes : 20 s ; mode de Defender : 10 s.
- **Le délai distant ne coupe plus un inventaire en cours.** L’inventaire rapide garde ses 55 s, le complet 150 s, et les logiciels, services, diagnostic et sondes leur durée annoncée ; une lecture arrêtée garde ce qu’elle a lu.
- **Compte choisi et OU de travail.** Les lectures distantes laissent le poste décider pour le compte choisi, y compris un compte saisi ; les écritures gardent leur validation préalable. L’OU de travail est restaurée depuis la base locale, sans lecture AD automatique.
- **Diagnostic.** Une « erreur CIM » affiche son code ; un arrêt de la lecture native consigne sa phase et son code, sans donnée du poste. Une erreur d’appel WinRM n’arrête plus le processus de lecture.
- **Interface.** Dans une fenêtre étroite, la zone de recherche du haut masque le raccourci puis le libellé au lieu de déborder. Le titre de la fenêtre nomme le poste, l’objet ou le sujet ouvert. Budgets en jours et en minutes.

**Limite connue.** Sur le poste de banc, le choix « CIM / WinRM » échoue encore sur chaque source avec le code 0x80070057, comme en 2.1.3 ; le mode Automatique lit par DCOM. Sur un poste lent, l’inventaire rapide peut atteindre son plafond de 55 s : les dernières sources sont « Interrompu » avec « Plafond total atteint ».

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

2.1.1 avait supprimé le contrôle préalable de Domain Admins pour le ping et les lectures distantes avec l’identité de la session Windows. Un compte saisi et toute écriture distante gardent leur validation.

## Validation de 2.1.4

[Run CI hébergé](https://github.com/M4D135/domenia-d120/actions/runs/43023042342) sur le commit publié, sous Windows (windows-2025) :

- compilation Windows ;
- suite C# complète, 3 065 tests, dont les 1 644 critiques ;
- 222 contrôles critiques du navigateur et 7 scénarios de simulation ;
- démarrage du ZIP avec WebView2 Evergreen ;
- connexion native jusqu’à l’Accueil hors connexion, puis fermeture propre.

Banc du 11 novembre sur un poste de test, avec des kits de la même source produit avant les seules retouches de documentation : inventaire rapide en Automatique par DCOM, 19 sources sur 27 avant le plafond de 55 s, sans arrêt du processus de lecture ; « CIM / WinRM » 0 sur 27 (limite ci-dessus). Aucune écriture AD n’a été exécutée. La recette utilisateur complète, notamment avec un compte hors Domain Admins, reste à effectuer ; la qualification CI ne constitue pas une validation en production.

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, lancé à la main ; aucun workflow ne publie de release.

## Historique

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases [v2.1.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.3), [v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2), [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
