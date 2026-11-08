# Domenia 2.0.8 — nom absent du DNS dans le relevé de présence

Correctif du 30 octobre 2026, issu du retour de terrain de David sur la version 2.0.7 en mode annuaire. La préparation et les contrôles CI ne constituent pas une recette utilisateur ; la validation visuelle native et la recette utilisateur restent en attente.

Extraire le nouveau pack dans un dossier distinct et vérifier son SHA256 avec `SHA256SUMS.txt`. La disposition reste celle de 2.0.7 : `Domenia.exe` et `wad` à la racine. Le format des données ne change pas (schéma 11, révision native 2) : une base de 2.0.5, 2.0.6 ou 2.0.7 s’ouvre telle quelle. Conserver les versions précédentes.

## Cas de terrain

Domaine de test, mode annuaire, OU de travail ADCC-Lab : cinq postes actifs. Quatre postes ont un nom résolu mais ne répondent pas au ping : W11-01 (10.77.0.20, VM supprimée), P111301VA765662 et P111301LY765715 (10.77.0.30), V111301VA765542 (10.77.0.31). V111301VA765183 n’a aucun enregistrement DNS. En 2.0.7, « Tout actualiser » affichait le relevé de présence en « Échec » avec « 0 poste en ligne sur 5 · 4 sans réponse · 1 non vérifié (sonde en erreur) », puis « Actualisation partielle » et « Reprendre », qui ne pouvait qu’obtenir la même réponse.

## À observer

- Si l’Accueil propose encore l’actualisation laissée par 2.0.7 (« Actualisation interrompue conservée … » avec « Reprendre »), commencer par « Reprendre » et confirmer « Reprendre l’actualisation interrompue » : elle se termine comme ci-dessous, avec un compte rendu terminé par « · 1 nom absent du DNS » et sans nouveau « Reprendre ».
- « Tout actualiser » : l’étape « Relevé de présence (ping) » est « Terminée » avec « 0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS ». Après la fin, « Étapes » la réaffiche.
- Le compte rendu « Tout actualisé : OU ADCC-Lab … » se termine par « · 1 nom absent du DNS ». Aucun « Reprendre », aucun « Échec », aucune « Actualisation partielle », aucune « sonde en erreur ». Quatre noms étant résolus, « aucun nom résolu » n’apparaît pas.
- Rechercher, postes de l’OU ADCC-Lab : la ligne de V111301VA765183 affiche « Nom absent du DNS » (2.0.7 : « Résolution DNS en erreur ») et reste dans le filtre « Erreur de ping ».
- Accueil, outils du tableau du parc › Provenance : dans « Vue affichée », la famille « Présence (ping) » range V111301VA765183 dans « Noms absents du DNS » (1) et non plus dans « En erreur » ; dans « Relevés par OU », le relevé de présence de cette actualisation est réussi, sans « lecture non confirmée ».
- Les points de la [recette 2.0.7](RECETTE-MANUELLE-V2.0.7.md) restent applicables.

## Si l’occasion se présente

Ne pas provoquer ces cas en modifiant le DNS, le réseau ou le poste.

- Délai DNS dépassé ou serveur DNS injoignable : l’étape de présence est « Incomplète » et nomme la cause (par exemple « délai DNS dépassé » ou « DNS indisponible »), comme le compte rendu « Actualisation partielle » ; « Reprendre » ne relance que les postes concernés.
- Aucun nom résolu (au moins deux noms absents ou sans adresse dans le DNS, aucun poste en ligne ni sans réponse) : l’étape reste « Terminée », mais l’étape et le compte rendu ajoutent « aucun nom résolu : vérifiez le DNS de ce poste » ; le DNS du poste qui exécute Domenia est alors à vérifier.
- Inventaire WMI aux lectures incomplètes ou refusées : l’étape est « Incomplète », et non plus « Échec ».

Ne noter comme réussies que les étapes effectivement exercées sur ce pack. Ce guide ne demande aucune écriture AD hors de l’OU de test, aucune modification du système ni redémarrage.
