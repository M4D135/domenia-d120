# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**

## Télécharger Domenia 2.1.10

Dernière version publiée : **2.1.10**, le 18 novembre 2026, construite depuis [`5db9d6b3`](https://github.com/M4D135/domenia-d120/commit/5db9d6b3a250041163864e9559f8d3b31ada3364). Le ZIP qualifié est publié sans reconstruction. Une seule édition est publiée, **PROD-LIGHT**.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD-LIGHT** | [Domenia_2.1.10_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.10/Domenia_2.1.10_PROD-LIGHT_Windows-x64.zip) (84 Mo) |
| **Sources** | [Sources exactes de 2.1.10](https://github.com/M4D135/domenia-d120/archive/refs/tags/v2.1.10.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.10/SHA256SUMS.txt) |

[Release v2.1.10](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.10) · [provenance du pack](packs/README.md) · [recette](v2/docs/RECETTE-MANUELLE-V2.1.10.md) · [mises à jour](v2/docs/MISES-A-JOUR.md).

SHA-256 du ZIP : `9aa7189bc72b8f9e3b317e1fa7230f71d2dbf2ff94fae043c41725baab68ccad`.

## Installation

Extraire le ZIP dans un nouveau dossier, vérifier son SHA-256 avec `SHA256SUMS.txt`, puis lancer `Domenia.exe`, avec `wad` à côté. Le runtime .NET est inclus.

PROD-LIGHT utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste, à partir de **140.0.3485.54**. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Sans l’un ni l’autre, un message propose les deux solutions ; rien n’est téléchargé.

Le schéma de données reste **11, révision 2**. La mise à jour **2.1.8 → 2.1.10** et la restauration vers 2.1.8 ont réussi avec les commandes `livraison`, en conservant à l’octet le fichier `wad/Domenia.settings.seed.json`. Le parcours proposé dans **Paramètres → Mises à jour** est décrit dans la [recette 2.1.10](v2/docs/RECETTE-MANUELLE-V2.1.10.md) ; il reste à vérifier sur le poste. Le passage depuis 2.1.9 n’a pas été exercé dans cette recette binaire. Pour une autre version ou édition, extraire le ZIP dans un nouveau dossier et conserver la version précédente localement.

## Correctifs de 2.1.10

- **Lecture d’une OU visible dans l’arbre.** Une branche déjà lue et affichée pouvait être refusée avec « OU introuvable : rien n’a été lu » lorsque l’ancien index des OU était vide. La recherche et « Afficher le contenu » utilisent désormais le cache de navigation de la branche choisie, y compris pour un conteneur imbriqué, tout en conservant le périmètre, le domaine et la session.
- **Recherche après une réponse LDAP vide.** Le correctif 2.1.9 est inclus : une réponse réussie sans objet peut omettre le contrôle de tri, sans interrompre les passes suivantes. Une réponse non vide sans tri confirmé ou un refus explicite restent refusés.
- **Historique au premier plan.** Les suggestions s’affichent devant les options de recherche ; leur fermeture écarte les réponses tardives.
- **Sélection et aperçu stables.** La vérification périodique d’une session inchangée ne vide plus la sélection des résultats et ne referme plus l’aperçu.

La navigation reste distincte de l’inventaire : développer une branche ne collecte pas implicitement tous ses objets. Les correctifs antérieurs de présence, de mises à jour et de configuration sont conservés.

Le catalogue compte 622 fonctions faites, 370 améliorées, aucune partielle ni à faire ; PST-001 reste abandonnée sur décision de David.

## Validation de 2.1.10

[Run de livraison Windows](https://github.com/M4D135/domenia-d120/actions/runs/44318608634) sur la source exacte du ZIP, sous Windows (windows-2025) :

- **3 090 tests C# complets réussis, dont 1 662 critiques**, avec les régressions du vrai cache de navigation et de ses services ; seul le transport LDAP est remplacé par une fixture ;
- **231 contrôles critiques du navigateur et huit parcours UI réussis**, soit 117 étapes ; le parcours de recherche vérifie une liste de 19 objets simulés, sa sélection et l’aperçu après une attente de 2,5 secondes ;
- deux démarrages du ZIP avec .NET privé 10.0.14 et WebView2 156.0.4314.58, sans échantillon non réactif ;
- choix de connexion, formulaire natif et Accueil hors connexion, puis fermeture propre.

La [compilation Windows séparée](https://github.com/M4D135/domenia-d120/actions/runs/44318608783) confirme Debug et Release sans erreur ni avertissement.

La recette binaire, dans le même run de livraison, compte **13 étapes réussies, aucun échec**. Elle utilise ce ZIP exact et la [release publique 2.1.8](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.8) : mise à jour **2.1.8 → 2.1.10** avec santé confirmée, fichier de configuration par défaut conservé à l’octet, puis restauration de 2.1.8 qui redémarre avec le même fichier.

**Limites.** La correction n’a pas été observée sur le domaine réel ; la recette des deux VM et la recette utilisateur restent à effectuer. Le parcours natif hors connexion ne démontre aucune authentification AD. La mise à jour depuis Paramètres et le passage 2.1.9 → 2.1.10 n’ont pas été exercés. Les mesures de démarrage concernent le runner, sans cache OS froid établi. Les résultats détaillés et les preuves sont consignés dans [REPRISE.md](v2/REPRISE.md).

## Sources et documentation

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md), [fonctions et parité](v2/docs/FEATURES.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le workflow de compilation Windows suit les changements de `v2/` sur `master`. La fabrication du pack est un workflow distinct, déclenchable manuellement et sur la branche corrective ; la publication de la release est manuelle.

## Historique

La release **v2.1.8 reste publiée**, comme référence de la recette de mise à jour et de restauration de 2.1.10. Le candidat 2.1.9 a été qualifié pour remise manuelle ; ses correctifs sont inclus dans 2.1.10.

Le dépôt a été recréé le 09/11/2026 : les packs 2.0.x ne sont plus publiés. Les releases v2.1.0 à v2.1.7 ont été retirées le 12/11/2026 ; leurs sources restent dans l’historique de `master`.
Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` contiennent la v1 (PowerShell 5.1 et WPF), conservée comme historique.
