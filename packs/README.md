# Packs Windows Domenia 2.1.10

Une seule édition est publiée : **PROD-LIGHT**. 2.1.10 corrige le refus d’une OU ou d’un conteneur visible dans l’arbre de Rechercher lorsque l’ancien index des OU est vide. La lecture des objets utilise la branche enregistrée dans le cache de navigation, sans élargir le périmètre ni remplir implicitement l’inventaire. Les correctifs 2.1.9 sont inclus : poursuite de la recherche après une passe LDAP vide sans contrôle de tri, historique au premier plan et maintien de la sélection et de l’aperçu pendant le suivi d’une session inchangée. Le schéma de données reste 11, révision 2.

Source : [`5db9d6b3`](https://github.com/M4D135/domenia-d120/commit/5db9d6b3a250041163864e9559f8d3b31ada3364). [Release v2.1.10](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.10), publiée le **18 novembre 2026 à 15 h 40, heure de Paris** (`14:40:11 UTC`) en dernière version, sans statut de brouillon ni de préversion. Le tag pointe sur la source exacte du ZIP qualifié ; aucune reconstruction pour la publication. L’autorisation utilisateur et les identifiants GitHub vérifiés figurent dans le manifeste.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.10_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.10/Domenia_2.1.10_PROD-LIGHT_Windows-x64.zip) | 84290042 | `9aa7189bc72b8f9e3b317e1fa7230f71d2dbf2ff94fae043c41725baab68ccad` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.10/SHA256SUMS.txt) : 108 octets, SHA-256 `dfbf3c6d9062f58949cfaf4bcff9f0c498076c9bbd1c8360ac5ba311d6d12a95`, copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Les tailles et les empreintes des deux assets ont été vérifiées par l’API GitHub et concordent avec les fichiers qualifiés. Le ZIP et `SHA256SUMS.txt` ont également été retéléchargés depuis leurs liens publics, sans cookie ni authentification, avec les mêmes tailles et empreintes.

`Domenia.exe` : 285 696 octets, SHA-256 `d792d25364ec1c8f44e1c124cc4b6b4e7c2bd77aab70feb3ff4c6b249ad74aa4`. Le ZIP contient 788 entrées, avec `Domenia.exe` et `wad/` à la racine.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/44318608634) : **3 090 tests C# complets réussis, dont 1 662 critiques**, **231 contrôles navigateur**, **huit parcours UI et leurs 117 étapes**, deux démarrages du paquet et parcours natif jusqu’à l’Accueil hors connexion réussis. La [compilation séparée](https://github.com/M4D135/domenia-d120/actions/runs/44318608783) confirme Debug et Release sans erreur ni avertissement. Les régressions C# utilisent le vrai cache différé/SQLite et les vrais services, avec un transport LDAP de test ; les objets des parcours UI sont simulés.

La recette des binaires, intégrée au même run de livraison sur un runner Windows hébergé jetable, compte **13 étapes, aucun échec**. Elle part du ZIP [2.1.8 publié](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.8), SHA-256 `32b3a1acc2c273d8f808d35f9096d3cc07b047970fae7378ecdfa690ac5bbd68`. La mise à jour **2.1.8 → 2.1.10** est confirmée par le vrai contrôle de santé ; `wad/Domenia.settings.seed.json` est conservé à l’octet. La restauration vers **2.1.8** conserve ce fichier et redémarre avec code 0. Ces opérations passent par les commandes `livraison`.

**Limites :** domaine réel, recette des deux VM et recette utilisateur non vérifiés ; aucune authentification AD réelle démontrée par le parcours hors connexion. La mise à jour depuis Paramètres et le chemin 2.1.9 → 2.1.10 n’ont pas été exercés. Les mesures de démarrage sont propres au runner, sans cache OS froid établi. Aucune écriture AD effectuée. Voir la [recette 2.1.10](../v2/docs/RECETTE-MANUELLE-V2.1.10.md) et les [preuves détaillées](../v2/REPRISE.md).

La release **v2.1.8 reste publiée** comme référence de cette recette. Le candidat 2.1.9 a été qualifié pour remise manuelle ; ses correctifs sont inclus dans 2.1.10. Les releases v2.1.0 à v2.1.7 ont été retirées le 12/11/2026, leurs sources restent dans l’historique de `master`. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
