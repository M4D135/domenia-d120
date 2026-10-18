# RC1.17.22 — contenu des pages accessible à Windows

Le modèle `UxWorkspaceHost` affichait le contenu sélectionné sans créer les conteneurs des onglets. UI Automation voyait `WorkspaceTabs` sans aucun enfant : la grille restait visible mais introuvable par son identifiant. Un `ItemsPresenter` de hauteur nulle réalise maintenant ces conteneurs, sans ajouter une barre d’onglets ni une cible de clic ou de tabulation. Les sélecteurs du banc utilisent également les `Uid` réels des boutons de navigation.

## Vérification native ciblée

- Windows PowerShell 5.1, session interactive : **28/28 étapes**, quatre parcours complets (navigation, défilement, fenêtres, opérations), **cinq captures 1920×1080 valides**, sans infobulle.
- Régression ciblée après correction du modèle (`scroll-regression/`) : grille retrouvée par `DgObjects`, défilement observé de 0 % à 100 %, puis retour à 0 %. Le parcours final sur le pack ne contient que trois lignes : ses deux événements de molette sont enregistrés comme « contenu non défilable » ; ils ne constituent pas une seconde preuve de déplacement.
- Huit règles du banc réussies. Démarrage `CheckOnly` du nouveau PROD réussi ; 172 fichiers runtime contrôlés et empreintes des deux archives relues dans la VM.
- Fabrication DEV/PROD et ses gardes réussies ; runtime identique dans les deux ZIP. `RC22-build.json` et `native/proof/Startup.json` lient les preuves aux archives.

Cible **Preview**, données fictives, aucun accès AD par ce parcours. Le verdict reste « Simulé seulement », `Qualified=false`, faute de relevé humain ; le code de sortie 1 du banc est donc attendu malgré les 28 étapes réussies. Les contrôles AD/WMI réels précédents restent distincts. Cela ne qualifie ni Narrateur à l’écoute, ni plusieurs moniteurs/DPI, ni une matrice cible, ni l’endurance sur 20 000 postes. Les limites du [complément RC21](../rc21-completion/README.md) restent applicables au périmètre personnel accepté par David.

## Traces et incident de laboratoire

Les échecs initiaux et le diagnostic UIA sont conservés, ainsi que le succès ciblé de sept étapes après correction. Une tentative a été interrompue par le verrouillage automatique ; à la demande de David, le verrouillage et la mise en veille ont été désactivés uniquement dans la VM jetable (`PreventLock.json`). La VM s’est ensuite arrêtée : l’événement Windows 1074 attribue cet arrêt au service wlms, pour expiration de l’évaluation (`LastShutdown.json`). Aucun contournement de licence n’a été appliqué ; aucune réussite n’est déduite des tentatives interrompues. Le rapport final provient du pack RC1.17.22 vérifié après redémarrage.

Les archives restent candidates et autonomes, composants embarqués conservés. Aucun droit de redistribution ni certificat n’est ajouté. Les preuves ont été poussées et vérifiées (`930061d`) avant suppression de `DOMENIA-RC21-FINAL`. Le disque et le dossier du clone sont supprimés, les sept VM préexistantes sont conservées sans changement de leur état, dont `CNAMTS-DC01` toujours démarré. Le reçu `FinalCleanup.json` contient les inventaires avant/après et les contrôles d’identité. Le premier reçu garde son échec de nettoyage : trois journaux VirtualBox subsistaient après suppression de la VM et du disque ; le reçu final prouve leur retrait et référence le SHA-256 du premier. Aucune VM cliente n’est encore nécessaire pour le périmètre personnel accepté.
