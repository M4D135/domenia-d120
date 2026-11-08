# TRV313 — anciens défauts livrés et sections personnelles

Le dernier audit ciblé a confirmé deux manques de production. Aucun changement du catalogue global ni promotion de statut.

## Corrections

- `Domenia-Boards.Model.ps1:955–993,1065` reconnaît quatre dispositions livrées anciennes, strictement inchangées : Parc RC1.13.0 (17 cartes), Parc score/points (17), Poste complet avant W11 (42), après W11 (44). La migration explicite D2 reconnaît désormais ces signatures exactes, ordre et casse compris. Source Builtin, absence de titre et absence de pause sont vérifiées séparément ; les identifiants sont ignorés comme en D1. Toute personnalisation ou `[]` empêche cette substitution. L’aperçu annonce le remplacement, puis seul le geste d’import peut écrire.
- Le défaut courant ou le vrai défaut d’équipe est proposé ; le texte Dashboard original reste dans la preuve atomique, avec les deux empreintes quand une configuration d’équipe intervient. La configuration d’équipe ne subit pas elle-même cette substitution. Widgets n’est pas ajouté à un Dashboard existant. Le refus d’une équipe incompatible reste entier, conformément aux gardes déjà acceptées ; aucune source n’est réécrite.
- `AccueilService.Clean` remplaçait toutes les sections par la catégorie du catalogue. Il conserve maintenant la section personnelle non vide, bornée à 80 caractères sans contrôles ; seule l’absence de section prend la catégorie. Le vrai import D1, l’édition et la restauration d’historique gardent ainsi le groupe choisi. Les champs invalides du document courant restent refusés par le codec d’historique.

## Preuves préparées

Cinq tests comportementaux écrits dans `LegacyBoardDeliveredMigrationTests.cs` : les quatre fixtures D1 exactes vers les vrais handlers de lecture, sept personnalisations empêchant la substitution, priorité d’équipe avec empreinte obligatoire et sans récursion, `[]` D2 concurrent inchangé octet pour octet, section personnelle traversant import/édition/historique/restauration. Les fixtures citent le SHA du fichier D1 lu ; aucune dépendance d’exécution vers dev/.

Aucun build ni test exécuté localement. `git diff --check` propre. Compilation et suites restent sous orchestration root sur Windows.

## Audit des restes voisins, hors extension de ce lot

- TRV310 : les presets Support/Inventaire/Santé existent dans Accueil, mais ne sont pas raccordés aux tableaux Poste/Logiciels.
- TRV311 : Accueil « Par défaut » utilise le catalogue D2 ; la disposition d’équipe D1 est prise lors de la migration initiale, pas rechargée par ce bouton. Poste/Logiciels n’ont pas de bouton Par défaut dédié.
- TRV312 : la migration des settings D1 n’est pas un sélecteur d’import/export des fichiers de disposition. Aucun parcours complet d’import/export de ces trois dispositions n’a été identifié dans leurs consommateurs.

Ces écarts sont des fonctions D1 existantes, distinctes des cinq versions restaurables demandées pour TRV313. Ils ne sont pas déclarés terminés. La recette visuelle et les suites réelles restent nécessaires ; aucune simple compilation ne les remplace.
