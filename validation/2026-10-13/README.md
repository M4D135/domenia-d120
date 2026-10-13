# Domenia 1.0 — améliorations et contrôles

## Périmètre de cette livraison

Cette passe complète les [30 points et demandes précédentes](../2026-10-12/completion-ledger-20261012.json).
Elle porte sur l’accès aux requêtes, la navigation, le rendu des tableaux et les diagnostics de réactivité.

Le [bilan point par point](BILAN.md) reprend les 30 améliorations initiales, les
12 demandes complémentaires et les 11 points de cette passe, avec leurs limites.

| Sujet | Changement |
|---|---|
| Rechercher | Une barre Requêtes regroupe 5 vues Annuaire, 152 modèles locaux et les recettes enregistrées ; filtre et favoris. |
| Résultats locaux | OU et profondeur de Recherche, calcul en arrière-plan, correspondants/inconnus/non-correspondants, compteurs et limite visibles. |
| Atelier | Dans Outils, accès par le crayon ; retour à la page et à l’onglet d’origine. |
| Navigation | Une requête locale conservée dans la navigation se réévalue localement ; annulation et changement de contexte rejettent les retours anciens. |
| Tableaux masqués | Les mises à jour de rendu sont regroupées jusqu’à l’affichage ; le contexte de session, d’OU et de poste est vérifié. |
| Catalogue des widgets | Catalogue indexé et réutilisé ; les lecteurs reçoivent des copies isolées. |
| Zoom et petites fenêtres | Zoom stabilisé à 150 %, retour à 100 % ; volet Options dans les fenêtres étroites ou basses, commandes accessibles au clavier et largeur d’OU conservée. |
| Sélecteurs | Un refus de lancement libère les commandes ; une réponse d’un contexte fermé ou remplacé est ignorée. |
| Journal et État du moteur | Durée des callbacks distincte des workers : médiane, p95 et maximum ; avertissements enrichis avec l’opération et le traitement. |

L’opération worker modifiée et relue est **LocalQuery**. Les empreintes du registre ont été régénérées ; le lanceur et les DLL épinglés sont conservés à l’octet.

## Preuves

Les contrôles locaux sont dans [local-checks.json](query-navigation/local-checks.json),
la revue dans [code-review.json](query-navigation/code-review.json).
La [campagne Windows hors ligne](query-navigation/qualification.json) valide **63 étapes** :
59 fichiers de tests distincts et 4 contrôles de compatibilité, fabrication, syntaxe et
démarrage. Le démarrage PROD en mode CheckOnly et les 37 contrôles de captures sont
vérifiés séparément. Les tentatives antérieures et leurs échecs sont conservés.

La fixture de charge couvre **5 000 postes et 78 sondes**, avec 14 572 contrôles réussis.
Elle ne mesure pas le débit d’une collecte sur un domaine réel. Les archives DEV et PROD
partagent les mêmes 93 fichiers runtime ; les sources livrées correspondent au DEV testé.

Les tentatives R4 et [R5](query-navigation/intermediate/r5-campaign/attempt-status.json)
ont rencontré une erreur `E_UNEXPECTED` pendant un chargement DLL, avant les cas.
Les [sept diagnostics isolés](query-navigation/intermediate/profile-diagnostic/diagnostic-summary.json)
ont chargé la DLL avec succès ; la cause reste **non établie**. La campagne finale
est une nouvelle exécution complète des mêmes archives, sans collecte concurrente
de rapports depuis la VM. Elle ne constitue pas la preuve d’une correction de cet incident.

Les [guides Word/PDF v1.0](../../DOC) sont prêts : 28 pages pour le technicien,
68 pour l’administrateur et 33 figures par guide. Les 96 pages ont été vérifiées
visuellement ; les [empreintes et contrôles documentaires](query-navigation/documentation-qa.json)
relient les documents aux captures de cette livraison.

### Recette interactive

La [recette humaine à la souris](query-navigation/interactive-gui.json) reste
**bloquée par le verrouillage du Mac : 0 scénario réussi, 9 non exécutés**.
Les captures proviennent de contrôles WPF natifs rendus dans la VM avec des données
fictives, en session 0. Elles ne prouvent pas une utilisation interactive complète.

## Mesure ciblée du rendu

Sur le même tableau synthétique masqué de 16 widgets, trois mesures après préparation
donnent **303 à 378 ms** pour le rendu complet, contre **0,32 à 0,74 ms** pour conserver
la mise à jour différée. Le rendu a ensuite lieu à l’ouverture du tableau : son coût
visible reste à payer. Ces mesures concernent ce scénario précis, sans accès AD.
Les [mesures brutes](query-navigation/intermediate/r5-campaign/Test-DomeniaBoards.json)
proviennent de la suite Boards réussie de R5 ; elles ne changent pas l’échec global
de cette tentative sur une autre suite.

## Portée des résultats

Les essais de charge utilisent des données fictives et les contrôles d’affichage utilisent WPF natif dans la VM Windows.
Ils ne remplacent pas une recette sur un domaine AD réel. Le callback de 551 ms fourni sans nom d’opération
ne permet pas de reproduire exactement l’événement utilisateur : les corrections réduisent le travail inutile
et ajoutent les informations nécessaires pour identifier les retours qui restent lents.
