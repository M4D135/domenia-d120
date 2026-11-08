# Revue RC1.17.4 — actualisation par OU

Demande : distinguer la base locale AD, les relevés des postes et le recalcul local, sans rajeunissement artificiel des dates.

## Contrat retenu

- Base locale : OU explicitement choisie et ses sous-OU, lecture AD puis reçu SQLite.
- Postes : tous les postes actifs de cette OU et de ses sous-OU, confirmation du nombre avant ping/WMI et sondes de widgets. Mesures forcées, réglage général du cache conservé.
- Les deux : base puis postes, après reçu de stockage de la même opération ; aucun enchaînement en cas de lecture partielle, erreur, annulation, changement de session ou de périmètre.
- Recalculer la vue : lecture locale seulement. Population et repères de synchronisation sont lus dans la même transaction SQLite.
- Dates distinctes pour couverture AD, couverture des mesures ping/WMI et calcul de la vue. Les repères sans profondeur connue ne certifient pas les sous-OU.

## Revue des contrats exécutables

Corps modifiés : LocalStore et LocalIndexRead. LocalStore conserve les repères OneLevel séparément des lectures Subtree. LocalIndexRead retourne les repères de synchronisation avec la population du même instantané et calcule les résumés de fraîcheur dans le worker. Aucun ajout d’opération réseau, aucune écriture AD, aucune modification des six binaires épinglés.

La révision des empreintes worker et de la référence preload est autorisée après inspection du diff : interface et événements des commandes, transport d’un identifiant d’opération jusqu’au reçu SQLite, guards de callback, ajout du module Refresh au chargeur fermé et aux fonctions du self-test. Les gardes d’authentification, d’écriture distante et de sélection ne changent pas.

## Limites de preuve

Le symptôme exact rapporté sur la base de l’utilisateur n’est pas reproduit sur son état original. Les défauts corrigés et scénarios de concurrence sont vérifiés séparément avec des fixtures. Les tests locaux PowerShell 7 ne qualifient pas Windows PowerShell 5.1. Les captures WPF de laboratoire utilisent des données fictives. L’accès CUA a signalé le Mac verrouillé ; aucune recette humaine à la souris n’est revendiquée.

## Décision de livraison

Le 13 octobre 2026, l’utilisateur confirme que le PC de test est éteint et prend en charge les tests Windows. Les archives restent au statut candidat, avec qualification Windows non évaluée. Les contrôles locaux sont conservés et la publication ne reprend pas les succès Windows d’une autre révision.

La revue croisée n’a trouvé aucun autre défaut bloquant. La date ping est celle du relevé qui inclut le ping : la classe native livrée n’expose pas l’instant ICMP séparé. Une ancienne présence n’est pas rajeunie par une simple sauvegarde ou un échec WMI.
