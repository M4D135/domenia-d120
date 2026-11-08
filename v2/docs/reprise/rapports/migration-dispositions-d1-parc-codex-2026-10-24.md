# Migration des dispositions D1 — API locale et Parc

Premier lot TRV313 : aperçu explicite des dispositions Parc, Poste et Logiciels dans les préférences D1, puis import effectif du Parc dans le consommateur Accueil. Le navigateur ne fournit aucun chemin ni document à importer : l’hôte relit les sources locales dans leur ordre de priorité et compare le SHA de l’aperçu. Les sources D1 restent intactes ; le texte original et sa provenance accompagnent la disposition D2.

L’écriture de la disposition et de sa preuve est conditionnelle et atomique sous le verrou interprocessus des préférences. Les choix D2 présents, y compris une liste vide, une version incompatible, un choix concurrent ou en attente de persistance, ne sont pas remplacés. Le document D2 est relu strictement avant import ; les champs de racine inconnus entraînent un refus sans réécriture. Le consommateur Accueil recharge aussi les dispositions volontairement vides après redémarrage.

La qualification des sources refuse les chemins réseau et les points de réanalyse ; lectures bornées, UTF-8 strict, JSON et provenance contrôlés. Capture et E2E utilisent des préférences en mémoire et n’exposent pas la migration des préférences de l’opérateur. L’interface présente Parc/Poste/Logiciels, explique les adaptations et demande une action explicite « Importer dans Accueil ».

Dix-neuf tests comportementaux sont écrits : consommation réelle par Accueil, liste vide persistante, priorité des sources et reprise historique, SHA et formats, concurrence de deux imports ou d’un choix D2, conservation des préférences incompatibles. Aucune suite n’est exécutée pendant le développement. Le journal VM et le manifeste de capture065 font foi pour la compilation.

Limites : ce lot ne migre pas encore les dispositions Poste et Logiciels, clairement annoncées non appliquées dans l’aperçu. Les présentations et groupes du Parc sont adaptés au catalogue D2 avec conservation du texte D1. La recette visuelle et la validation finale dans les deux VM restent à faire ; TRV313 et la parité globale ne sont pas déclarés terminés.
