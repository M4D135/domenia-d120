# Complément démo — sélection locale de fichiers

Après gel des 45 fichiers de session, la revue a identifié les inputs navigateur de fichiers des anciennes pages (notamment partage de recettes), distincts du sélecteur hôte limité aux exports privés. La coque installe désormais une garde capture pour click/change et drop/paste contenant des fichiers, avant les handlers de page et avant FileReader. Elle refuse aussi tant que le mode n’est pas qualifié. Le mode historique --simulation/E2E reste compatible ; la garde concerne la session --demo-session. Les contenus texte collés explicitement sont des saisies en mémoire, sans lecture de chemin par le moteur.

Deux tests web discriminants écrits, aucun exécuté. app.js/run.mjs/DEMONSTRATION.md évoluent après candidate-demo-111 ; les octets de cette capture restent intacts. Aucun changement Program/Composition.
