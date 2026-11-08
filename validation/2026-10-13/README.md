# Domenia 1.0 — améliorations et contrôles

## Recherche progressive et délais — RC1.17.6

La recherche attend désormais 120 secondes **sans nouvelle ligne AD**, avec un plafond total de 900 secondes. Son horloge démarre au dispatch ; le cache et le rendu de la liste ne prolongent pas l’attente. Les pages LDAP passent de 40 à 250 objets, les attentes serveur/client à 60/90 secondes. Les anciens réglages trop courts sont relevés automatiquement. Les erreurs du fournisseur restent traitées et peuvent interrompre une lecture plus tôt.

91 cas locaux réussis sous PowerShell 7.4.20 : 26 cas de délais (87 assertions), 23 cas de worker/câblage (39 assertions), 42 cas de périmètre OU et générations. Le worker et ses convertisseurs ont traité 5 000 objets synthétiques ; une course sur le snapshot de progression est couverte. Audits statiques réussis, 94 fichiers runtime identiques entre DEV/PROD et correspondance de tous les fichiers DEV avec les sources. **Aucun test Windows, WPF ou AD réel pour cette révision.**

Guides v1.0 Word/PDF à jour : technicien 28 pages, administrateur 70 pages. 70 pages nouvellement relues, 28 inchangées et vérifiées par empreinte ; aucune nouvelle capture de l’application.

[Revue et recette](search-progress/REVIEW.md) · [Résultats](search-progress/qualification.json) · [Contrôle documentaire](search-progress/documentation-qa.json) · [Manifestes des packs](../../packs/manifest.json)

Publication RC1.17.6 : commit `fb03e2b16a490d1145923629986f8cd76b0a5b53` poussé sur `master`. Les deux ZIP retéléchargés depuis ce commit correspondent aux tailles et SHA-256 livrés ([preuve GitHub](search-progress/github-packs.json)).

## Délai de recherche et liste partielle — RC1.17.5

Le dépassement de 45 secondes observé dans le journal n’établit pas une panne AD. Le bandeau affiche désormais « Dernière requête AD : délai dépassé » en avertissement ; une véritable erreur réseau conserve le mode hors ligne et les protections associées. Une lecture AD réussie rétablit la connexion affichée.

Le compteur des résultats distingue les lignes visibles/chargées d’une liste exhaustive : « Liste partielle » après interruption, « Chargement… » pendant la lecture, « Limite atteinte » lorsque le plafond est atteint. La cause de la lenteur du domaine de l’utilisateur reste à diagnostiquer.

Contrôles locaux : 14 cas/58 assertions pour l’état AD et le callback, 12 cas/27 assertions pour les compteurs et callbacks de recherche, 8 cas de règles cache et 2 cas de badge. Tous réussis sous PowerShell 7.4.20. Audits statiques et fabrication des packs réussis ; 94 fichiers runtime identiques entre DEV et PROD. **Windows, WPF et AD réel non exécutés pour cette révision.**

[Revue et retour utile](ad-timeout/REVIEW.md) · [Résultats](ad-timeout/qualification.json) · [Manifestes des packs](../../packs/manifest.json)

Publication : commit `638d0c9123271ca07e5db53fd519b7a1a7ce2df0` poussé sur `master`. Les ZIP retéléchargés depuis ce commit correspondent aux empreintes livrées ([preuve](ad-timeout/github-packs.json)). Les guides DOCX/PDF conservent 97 pages : dix pages modifiées relues, 87 identiques aux rendus précédemment vérifiés ([preuve documentaire](ad-timeout/documentation-qa.json)).

## Actualisation de l’OU — RC1.17.4

| Action | Effet |
|---|---|
| Base locale | Relit AD pour l’OU choisie et ses sous-OU, puis enregistre SQLite. |
| Postes (ping/WMI) | Prépare tous les postes actifs de cette OU et de ses sous-OU, confirme le nombre, puis relève le ping, l’inventaire léger et les sondes des widgets. |
| Les deux | Enchaîne la collecte après le reçu de sauvegarde de la même opération. |
| Recalculer la vue | Relit uniquement la base ; conserve les dates de collecte. |
| Arrêter | Empêche toute phase suivante ; conserve les écritures déjà engagées. |

Les dates AD, des relevés ping/WMI et du calcul sont distinctes. La couverture affiche N/M postes et l’intervalle des dates utilisables. Une tentative partielle ne remplace pas une lecture complète ; une lecture sans sous-OU ne certifie pas leur fraîcheur. Un calcul devenu périmé pendant une sauvegarde ne réaffiche plus les anciens chiffres.

### Contrôles effectués

- Orchestration : 43 cas réussis sous PowerShell 7.4.20, avec doubles de transport.
- Fraîcheur : 16 cas purs et de callback, 33 assertions réussies.
- Actions de base : 19 assertions réussies ; règle de fraîcheur existante : 6 assertions.
- Garde des distributions Python : 50 tests réussis.
- Audits statiques, chargeur fermé, contrats worker, version et composants épinglés : réussis.
- DEV et PROD : 94 fichiers runtime identiques ; six binaires épinglés inchangés.

[Résultats et limites](ou-refresh/qualification.json) · [Revue du code](ou-refresh/REVIEW.md) · [Manifeste des packs](../../packs/manifest.json)

### Publication

Le commit `d583a2db33e584410854548f19149ddbaedd24d4` a été poussé sur `master`. Les deux ZIP ont été retéléchargés depuis GitHub à ce commit : tailles et SHA-256 conformes au manifeste ([preuve](ou-refresh/github-packs.json)). Les guides technicien et administrateur DOCX/PDF sont inclus ; leurs 97 pages ont été relues ([preuve documentaire](ou-refresh/documentation-qa.json)).

### Validation Windows à effectuer

Le PC de test étant éteint, l’utilisateur a choisi de tester lui-même cette révision. **Aucune nouvelle campagne Windows, WPF, SQLite natif ou AD réel n’est revendiquée.** Les contrôles PowerShell 7 ne valent pas qualification Windows PowerShell 5.1. La campagne préparée et les captures sont conservées dans [le dossier de reprise](ou-refresh/r1/).

Pour les retours, relever l’OU et les sous-OU choisies, le bouton utilisé, les dates AD/ping/WMI avant et après recalcul, le nombre de postes annoncé et le message final. Le petit [parcours de recette](ou-refresh/RECETTE.md) permet de vérifier les quatre actions sans modifier l’annuaire.

## Autres améliorations et preuves

Le [bilan point par point](BILAN.md) reprend les 30 améliorations initiales, les 12 demandes complémentaires et la navigation par requêtes. La [livraison RC1.17.3](query-navigation/BILAN-LIVRAISON.md) conserve ses preuves Windows, distinctes de cette révision.
