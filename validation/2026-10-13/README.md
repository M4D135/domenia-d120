# Domenia 1.0 — améliorations et contrôles

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
